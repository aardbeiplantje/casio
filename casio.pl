#!/usr/bin/perl
#
# casio.pl - BLE probe tool for Casio watches (e.g. ABL-100WE)
#
# Built from the same raw ATT/L2CAP approach as medisana.pl.
#
# Default behavior:
#   - identify: read Device Name (0x2A00) and Manufacturer Name (0x2A29)
#   - battery : read Battery Level (0x2A19)
#
# Optional:
#   - services: enumerate all primary GATT services
#

use strict;
use warnings;
use bytes;
use Getopt::Long;

my %opts = (
    device          => undef,
    addr_type       => 'public',
    connect_timeout => 8,
    listen_seconds  => 0,
    debug           => 0,
    action_timeout  => 6,
);

my ($do_identify, $do_battery, $do_services, $do_chars, $do_dump_custom) = (0, 0, 0, 0, 0);

GetOptions(
    'device|d=s'           => \$opts{device},
    'addr-type=s'          => \$opts{addr_type},
    'connect-timeout=f'    => \$opts{connect_timeout},
    'listen-seconds=f'     => \$opts{listen_seconds},
    'action-timeout=f'     => \$opts{action_timeout},
    'identify'             => \$do_identify,
    'battery'              => \$do_battery,
    'services'             => \$do_services,
    'chars'                => \$do_chars,
    'dump-custom'          => \$do_dump_custom,
    'debug|v+'             => \$opts{debug},
    'help|h'               => sub { print_usage(); exit 0; },
) or do { print_usage(); exit 1; };

unless ($opts{device}) {
    print STDERR "Error: -d / --device is required\n";
    print_usage();
    exit 1;
}
unless ($opts{device} =~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
    print STDERR "Error: Invalid Bluetooth address format\n";
    exit 1;
}
if ($opts{addr_type} !~ /^(?:public|random)$/i) {
    print STDERR "Error: --addr-type must be 'public' or 'random'\n";
    exit 1;
}

# Default: identify + battery
if (!$do_identify && !$do_battery && !$do_services && !$do_chars && !$do_dump_custom) {
    $do_identify = $do_battery = 1;
}

my $watch = Casio::BLE->new(%opts);
exit $watch->run(
    identify => $do_identify,
    battery  => $do_battery,
    services => $do_services,
    chars    => $do_chars,
    dump_custom => $do_dump_custom,
);

package Casio::BLE;

use Errno  qw(EAGAIN EINPROGRESS);
use Fcntl  qw(O_NONBLOCK F_SETFL F_GETFL);
use Socket qw(SOCK_SEQPACKET SOL_SOCKET SO_ERROR);

use constant {
    AF_BLUETOOTH               => 31,
    BTPROTO_L2CAP              => 0,
    BDADDR_LE_PUBLIC           => 0x01,
    BDADDR_LE_RANDOM           => 0x02,

    ATT_ERROR_RSP              => 0x01,
    ATT_EXCHANGE_MTU_REQ       => 0x02,
    ATT_EXCHANGE_MTU_RSP       => 0x03,
    ATT_READ_BY_TYPE_REQ       => 0x08,
    ATT_READ_BY_TYPE_RSP       => 0x09,
    ATT_READ_REQ               => 0x0A,
    ATT_READ_RSP               => 0x0B,
    ATT_READ_BY_GROUP_TYPE_REQ => 0x10,
    ATT_READ_BY_GROUP_TYPE_RSP => 0x11,

    GATT_PRIMARY_SERVICE_UUID  => 0x2800,
    GATT_CHARACTERISTIC_UUID   => 0x2803,
};

sub new {
    my ($class, %o) = @_;
    bless {
        device          => $o{device},
        addr_type       => lc($o{addr_type} // 'public'),
        connect_timeout => $o{connect_timeout} // 8,
        listen_seconds  => $o{listen_seconds} // 0,
        action_timeout  => $o{action_timeout} // 6,
        debug           => $o{debug} // 0,
        socket          => undef,
    }, $class;
}

sub run {
    my ($self, %todo) = @_;

    print "Casio BLE Probe Tool\n";
    print "====================\n\n";
    print "Device: $self->{device}\n";
    print "AddrType: $self->{addr_type}\n";
    print "Listen: $self->{listen_seconds}s\n" if $self->{listen_seconds} > 0;

    my $connected = $self->{listen_seconds} > 0
        ? $self->wait_for_connect($self->{listen_seconds})
        : $self->ble_connect();

    unless ($connected) {
        print STDERR "ERROR: BLE connection failed\n";
        return 1;
    }

    $self->exchange_mtu(128);

    my $rc = 0;

    if ($todo{identify}) {
        my $name = $self->read_ascii_char_by_uuid16(0x2A00);
        my $mfg  = $self->read_ascii_char_by_uuid16(0x2A29);

        if (defined $name) {
            print "Name:          $name\n";
        } else {
            print "Name:          <not available>\n";
            $rc = 1;
        }

        if (defined $mfg) {
            print "Manufacturer:  $mfg\n";
        } else {
            print "Manufacturer:  <not available>\n";
        }
    }

    if ($todo{battery}) {
        my $b = $self->read_battery_percent();
        if (defined $b) {
            printf "Battery:       %d%%\n", $b;
        } else {
            print "Battery:       <not available>\n";
            $rc = 1;
        }
    }

    if ($todo{services}) {
        my @services = $self->list_primary_services();
        if (@services) {
            print "PrimaryServices:\n";
            for my $s (@services) {
                printf "  0x%04X-0x%04X  %s\n", $s->{start}, $s->{end}, $s->{uuid};
            }
        } else {
            print "PrimaryServices: <none or not readable>\n";
            $rc = 1;
        }
    }

    if ($todo{chars}) {
        my @services = $self->list_primary_services();
        if (!@services) {
            print "Characteristics: <no services discovered>\n";
            $rc = 1;
        } else {
            print "Characteristics:\n";
            for my $svc (@services) {
                printf "  Service 0x%04X-0x%04X  %s\n", $svc->{start}, $svc->{end}, $svc->{uuid};
                my @chars = $self->list_characteristics_in_range($svc->{start}, $svc->{end});
                if (!@chars) {
                    print "    <none>\n";
                    next;
                }
                for my $c (@chars) {
                    printf "    decl=0x%04X value=0x%04X props=0x%02X uuid=%s\n",
                        $c->{decl_handle}, $c->{value_handle}, $c->{props}, $c->{uuid};
                }
            }
        }
    }

    if ($todo{dump_custom}) {
        my $target_uuid = '26eb000d-b012-49a8-b1f8-394fb2032b0f';
        my @services = $self->list_primary_services();
        my ($svc) = grep { lc($_->{uuid}) eq $target_uuid } @services;

        if (!$svc) {
            print "CustomDump: service $target_uuid not found\n";
            $rc = 1;
        } else {
            printf "CustomDump: service 0x%04X-0x%04X %s\n", $svc->{start}, $svc->{end}, $svc->{uuid};
            my @chars = $self->list_characteristics_in_range($svc->{start}, $svc->{end});
            if (!@chars) {
                print "  <no characteristics>\n";
                $rc = 1;
            } else {
                for my $c (@chars) {
                    printf "  char value=0x%04X props=0x%02X uuid=%s\n",
                        $c->{value_handle}, $c->{props}, $c->{uuid};

                    # Property bit 0x02 indicates Read support.
                    if ($c->{props} & 0x02) {
                        my $raw = $self->read_char_by_handle($c->{value_handle});
                        if (defined $raw) {
                            my $hex = join(' ', map { sprintf '%02X', $_ } unpack('C*', $raw));
                            my $txt = $raw;
                            $txt =~ s/\x00+$//;
                            $txt =~ s/[^\x20-\x7E]/./g;
                            print "    read:  $hex\n";
                            print "    ascii: $txt\n" if length($txt);
                        } else {
                            print "    read:  <failed>\n";
                        }
                    } else {
                        print "    read:  <not readable>\n";
                    }
                }
            }
        }
    }

    $self->ble_disconnect();
    return $rc;
}

sub ble_connect {
    my ($self) = @_;
    my @oct    = split(':', $self->{device});
    my $bdaddr = pack('C6', map { hex($_) } reverse @oct);
    my $atype  = ($self->{addr_type} eq 'random') ? BDADDR_LE_RANDOM : BDADDR_LE_PUBLIC;

    socket(my $sock, AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP) or return 0;

    bind($sock, pack('S S a6 S S', AF_BLUETOOTH, 0, "\0" x 6, 4, BDADDR_LE_PUBLIC))
        or do { close($sock); return 0; };

    my $peer = pack('S S a6 S S', AF_BLUETOOTH, 0, $bdaddr, 4, $atype);
    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) | O_NONBLOCK);

    my $connected = connect($sock, $peer);
    if (!$connected && !($! == EINPROGRESS || $! == EAGAIN)) {
        $self->debug("connect() immediate fail: $!");
        close($sock);
        return 0;
    }

    unless ($connected) {
        my $deadline = time() + ($self->{connect_timeout} > 0 ? $self->{connect_timeout} : 8);
        my $done = 0;
        while (time() < $deadline) {
            my $fh = fileno($sock);
            my $wvec = '';
            vec($wvec, $fh, 1) = 1;
            my $n = select(undef, $wvec, my $evec = $wvec, 0.5);
            next unless defined($n) && $n > 0;
            my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
            my $eno = $err ? unpack('I', $err) : 0;
            if (!$eno) { $done = 1; last; }
            next if $eno == EINPROGRESS || $eno == EAGAIN;
            last;
        }
        unless ($done) {
            $self->debug('connect timeout');
            close($sock);
            return 0;
        }
    }

    my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
    if ($err && unpack('I', $err)) { close($sock); return 0; }

    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) & ~O_NONBLOCK);
    $self->{socket} = $sock;
    return 1;
}

sub wait_for_connect {
    my ($self, $listen_seconds) = @_;
    my $deadline = time() + ($listen_seconds > 0 ? $listen_seconds : 0);
    my $attempt  = 0;

    while (time() <= $deadline) {
        $attempt++;
        $self->debug("listen attempt $attempt");
        return 1 if $self->ble_connect();
        select(undef, undef, undef, 0.35);
    }

    return 0;
}

sub ble_disconnect {
    my ($self) = @_;
    if ($self->{socket}) {
        close($self->{socket});
        $self->{socket} = undef;
    }
}

sub att_request {
    my ($self, $req, $timeout) = @_;
    $timeout //= $self->{action_timeout};
    return unless $self->{socket};
    syswrite($self->{socket}, $req) or return;

    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, $timeout);
    return unless defined($n) && $n > 0;

    my ($rsp, $r) = ('');
    $r = sysread($self->{socket}, $rsp, 512);
    return unless defined($r) && $r > 0;
    return $rsp;
}

sub exchange_mtu {
    my ($self, $mtu) = @_;
    my $rsp = $self->att_request(pack('C S<', ATT_EXCHANGE_MTU_REQ, $mtu), 2.0);
    return unless defined $rsp && length($rsp) >= 3
                  && ord(substr($rsp, 0, 1)) == ATT_EXCHANGE_MTU_RSP;
    $self->debug(sprintf('MTU: client=%d server=%d', $mtu, unpack('S<', substr($rsp, 1, 2))));
}

sub find_char_value_handle_by_uuid16 {
    my ($self, $uuid16) = @_;
    my $start = 0x0001;
    my $end   = 0xFFFF;

    while ($start <= $end) {
        my $rsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_TYPE_REQ, $start, $end, GATT_CHARACTERISTIC_UUID),
            2.0
        );
        last unless defined $rsp && length($rsp) >= 2;

        my $op = ord(substr($rsp, 0, 1));
        last if $op != ATT_READ_BY_TYPE_RSP;

        my $elen = ord(substr($rsp, 1, 1));
        last if $elen < 7;

        my ($pos, $last_decl) = (2, $start);
        while ($pos + $elen <= length($rsp)) {
            my $e     = substr($rsp, $pos, $elen);
            my $decl  = unpack('S<', substr($e, 0, 2));
            my $vhand = unpack('S<', substr($e, 3, 2));
            my $uuid  = unpack('S<', substr($e, 5, 2));
            if ($uuid == $uuid16) {
                return $vhand;
            }
            $last_decl = $decl;
            $pos += $elen;
        }
        $start = $last_decl + 1;
    }

    return undef;
}

sub read_char_by_handle {
    my ($self, $handle) = @_;
    my $rsp = $self->att_request(pack('C S<', ATT_READ_REQ, $handle), 2.0);
    return undef unless defined $rsp && length($rsp) >= 1;
    return undef unless ord(substr($rsp, 0, 1)) == ATT_READ_RSP;
    return substr($rsp, 1);
}

sub read_ascii_char_by_uuid16 {
    my ($self, $uuid16) = @_;
    my $handle = $self->find_char_value_handle_by_uuid16($uuid16);
    return undef unless defined $handle;
    my $raw = $self->read_char_by_handle($handle);
    return undef unless defined $raw;

    my $txt = $raw;
    $txt =~ s/\x00+$//;
    $txt =~ s/[\x00-\x1F\x7F]/?/g;
    return $txt;
}

sub read_battery_percent {
    my ($self) = @_;
    my $handle = $self->find_char_value_handle_by_uuid16(0x2A19);
    return undef unless defined $handle;
    my $raw = $self->read_char_by_handle($handle);
    return undef unless defined $raw && length($raw) >= 1;
    return unpack('C', substr($raw, 0, 1));
}

sub list_primary_services {
    my ($self) = @_;
    my @out;
    my $start = 0x0001;
    my $end   = 0xFFFF;

    while ($start <= $end) {
        my $rsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_GROUP_TYPE_REQ, $start, $end, GATT_PRIMARY_SERVICE_UUID),
            2.0
        );
        last unless defined $rsp && length($rsp) >= 2;

        my $op = ord(substr($rsp, 0, 1));
        last if $op != ATT_READ_BY_GROUP_TYPE_RSP;

        my $elen = ord(substr($rsp, 1, 1));
        last if $elen < 6;

        my ($pos, $last_end) = (2, $start);
        while ($pos + $elen <= length($rsp)) {
            my $e = substr($rsp, $pos, $elen);
            my ($h1, $h2) = unpack('S< S<', substr($e, 0, 4));
            my $uuid_raw = substr($e, 4, $elen - 4);
            push @out, {
                start => $h1,
                end   => $h2,
                uuid  => _uuid_to_str($uuid_raw),
            };
            $last_end = $h2;
            $pos += $elen;
        }
        $start = $last_end + 1;
    }

    return @out;
}

sub list_characteristics_in_range {
    my ($self, $start, $end) = @_;
    my @out;
    my $cursor = $start;

    while ($cursor <= $end) {
        my $rsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_TYPE_REQ, $cursor, $end, GATT_CHARACTERISTIC_UUID),
            2.0
        );
        last unless defined $rsp && length($rsp) >= 2;

        my $op = ord(substr($rsp, 0, 1));
        last if $op != ATT_READ_BY_TYPE_RSP;

        my $elen = ord(substr($rsp, 1, 1));
        last if $elen < 7;

        my ($pos, $last_decl) = (2, $cursor);
        while ($pos + $elen <= length($rsp)) {
            my $e = substr($rsp, $pos, $elen);
            my $decl  = unpack('S<', substr($e, 0, 2));
            my $props = unpack('C',  substr($e, 2, 1));
            my $vhand = unpack('S<', substr($e, 3, 2));
            my $uuid_raw = substr($e, 5, $elen - 5);

            push @out, {
                decl_handle  => $decl,
                value_handle => $vhand,
                props        => $props,
                uuid         => _uuid_to_str($uuid_raw),
            };

            $last_decl = $decl;
            $pos += $elen;
        }

        $cursor = $last_decl + 1;
    }

    return @out;
}

sub _uuid_to_str {
    my ($raw) = @_;
    if (length($raw) == 2) {
        return sprintf('0x%04X', unpack('S<', $raw));
    }
    if (length($raw) == 16) {
        my @b = unpack('C*', reverse $raw);
        return sprintf(
            '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
            @b
        );
    }
    return 'unknown';
}

sub debug {
    my ($self, $msg) = @_;
    print "  [DEBUG] $msg\n" if $self->{debug};
}

1;

package main;

sub print_usage {
    print <<"EOF";
Usage: $0 -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (defaults to --identify --battery):
  --identify          Read Device Name (2A00) and Manufacturer (2A29)
  --battery           Read Battery Level (2A19)
  --services          List primary GATT services
    --chars             List characteristics for each primary service
    --dump-custom       Dump readable chars for Casio custom service

Required:
  -d, --device ADDR   BLE MAC address

Options:
  --addr-type TYPE    public|random (default: public)
  --connect-timeout S Connect timeout seconds (default: 8)
    --listen-seconds S  Keep retrying connect for S seconds (watch-initiated mode)
  --action-timeout S  ATT read timeout seconds (default: 6)
  -v, --debug         Verbose output
  -h, --help          Show this help

Examples:
  $0 -d EB:5E:BB:56:29:37 --addr-type public --identify --battery
  $0 -d EB:5E:BB:56:29:37 --addr-type public --services
    $0 -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --chars
    $0 -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --dump-custom -v
    $0 -d EB:5E:BB:56:29:37 --addr-type public --listen-seconds 45 --identify --battery
  $0 -d EB:5E:BB:56:29:37 --addr-type random --identify --battery -v
EOF
}
