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
use Time::Local qw(timelocal);

my %opts = (
    device          => undef,
    addr_type       => 'public',
    connect_timeout => 8,
    listen_seconds  => 0,
    fetch_live_seconds => 6,
    response_timeout_ms => 2500,
    notify_listen_sec => 10,
    trace_file      => 'casio_trace.log',
    trace_poll11    => 1,
    trace_seed      => 1,
    debug           => 0,
    action_timeout  => 6,
);

my ($do_identify, $do_battery, $do_services, $do_chars, $do_dump_custom, $do_fetch, $do_dump_all) = (0, 0, 0, 0, 0, 0, 0);
my ($do_listen, $read_handle, $write_req_handle, $write_cmd_handle, $write_hex, $subscribe_handle, $notify_handle) = (0, undef, undef, undef, undef, undef, undef);
my $do_trace = 0;

GetOptions(
    'device|d=s'           => \$opts{device},
    'addr-type=s'          => \$opts{addr_type},
    'connect-timeout=f'    => \$opts{connect_timeout},
    'listen-seconds=f'     => \$opts{listen_seconds},
    'fetch-live-seconds=f' => \$opts{fetch_live_seconds},
    'response-timeout-ms=i' => \$opts{response_timeout_ms},
    'notify-listen-sec=f'  => \$opts{notify_listen_sec},
    'trace'                => \$do_trace,
    'trace-file=s'         => \$opts{trace_file},
    'trace-poll11!'        => \$opts{trace_poll11},
    'trace-seed!'          => \$opts{trace_seed},
    'action-timeout=f'     => \$opts{action_timeout},
    'read-handle=s'        => \$read_handle,
    'write-req-handle=s'   => \$write_req_handle,
    'write-cmd-handle=s'   => \$write_cmd_handle,
    'write-hex=s'          => \$write_hex,
    'subscribe-handle=s'   => \$subscribe_handle,
    'notify-handle=s'      => \$notify_handle,
    'listen'               => \$do_listen,
    'identify'             => \$do_identify,
    'battery'              => \$do_battery,
    'services'             => \$do_services,
    'chars'                => \$do_chars,
    'dump-custom'          => \$do_dump_custom,
    'dump-all'             => \$do_dump_all,
    'fetch'                => \$do_fetch,
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
if ($opts{response_timeout_ms} < 100 || $opts{response_timeout_ms} > 30000) {
    print STDERR "Error: --response-timeout-ms must be in 100..30000\n";
    exit 1;
}
if ($opts{notify_listen_sec} < 0 || $opts{notify_listen_sec} > 3600) {
    print STDERR "Error: --notify-listen-sec must be in 0..3600\n";
    exit 1;
}
if (!defined($opts{trace_file}) || $opts{trace_file} eq '') {
    print STDERR "Error: --trace-file cannot be empty\n";
    exit 1;
}

for my $ref (\$read_handle, \$write_req_handle, \$write_cmd_handle, \$subscribe_handle, \$notify_handle) {
    next unless defined $$ref;
    my $h = parse_handle($$ref);
    defined($h)
        or do { print STDERR "Error: Handle values must be hex or decimal in range 0x0001..0xFFFF\n"; exit 1; };
    $$ref = $h;
}

if (defined $write_req_handle || defined $write_cmd_handle) {
    defined $write_hex
        or do { print STDERR "Error: --write-hex is required with --write-req-handle / --write-cmd-handle\n"; exit 1; };
}

my $write_bytes;
if (defined $write_hex) {
    $write_bytes = parse_hex_bytes($write_hex);
    defined($write_bytes)
        or do { print STDERR "Error: --write-hex must be bytes like 'AA BB 01 02' or 'AABB0102'\n"; exit 1; };
}

if (defined $write_req_handle && defined $write_cmd_handle) {
    print STDERR "Error: Use only one of --write-req-handle or --write-cmd-handle\n";
    exit 1;
}

# Default: identify + battery
if (!$do_identify && !$do_battery && !$do_services && !$do_chars && !$do_dump_custom && !$do_fetch
    && !$do_listen
    && !$do_trace
    && !defined($read_handle) && !defined($write_req_handle) && !defined($write_cmd_handle) && !defined($subscribe_handle)) {
    $do_identify = $do_battery = 1;
}

my $watch = Casio::BLE->new(%opts);
exit $watch->run(
    identify => $do_identify,
    battery  => $do_battery,
    services => $do_services,
    chars    => $do_chars,
    dump_custom => $do_dump_custom,
    dump_all => $do_dump_all,
    fetch => $do_fetch,
    read_handle => $read_handle,
    write_req_handle => $write_req_handle,
    write_cmd_handle => $write_cmd_handle,
    write_bytes => $write_bytes,
    subscribe_handle => $subscribe_handle,
    notify_handle => $notify_handle,
    listen => $do_listen,
    trace => $do_trace,
    trace_file => $opts{trace_file},
    trace_poll11 => $opts{trace_poll11} ? 1 : 0,
    trace_seed => $opts{trace_seed} ? 1 : 0,
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
    ATT_WRITE_CMD              => 0x52,
    ATT_WRITE_REQ              => 0x12,
    ATT_WRITE_RSP              => 0x13,
    ATT_READ_BY_TYPE_REQ       => 0x08,
    ATT_READ_BY_TYPE_RSP       => 0x09,
    ATT_READ_REQ               => 0x0A,
    ATT_READ_RSP               => 0x0B,
    ATT_READ_BY_GROUP_TYPE_REQ => 0x10,
    ATT_READ_BY_GROUP_TYPE_RSP => 0x11,
    ATT_HANDLE_VALUE_NOTIF     => 0x1B,
    ATT_FIND_INFORMATION_REQ   => 0x04,
    ATT_FIND_INFORMATION_RSP   => 0x05,

    GATT_PRIMARY_SERVICE_UUID  => 0x2800,
    GATT_CHARACTERISTIC_UUID   => 0x2803,
    GATT_CLIENT_CHARACTERISTIC_CONFIG => 0x2902,
};

sub new {
    my ($class, %o) = @_;
    bless {
        device          => $o{device},
        addr_type       => lc($o{addr_type} // 'public'),
        connect_timeout => $o{connect_timeout} // 8,
        listen_seconds  => $o{listen_seconds} // 0,
        fetch_live_seconds => $o{fetch_live_seconds} // 6,
        action_timeout  => defined($o{response_timeout_ms})
            ? ($o{response_timeout_ms} / 1000.0)
            : ($o{action_timeout} // 6),
        notify_listen_sec => $o{notify_listen_sec} // 10,
        debug           => $o{debug} // 0,
        socket          => undef,
        notif_queue     => [],
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

    if ($todo{dump_all}) {
        my @services = $self->list_primary_services();
        if (!@services) {
            print "DumpAll: <no services discovered>\n";
            $rc = 1;
        } else {
            print "DumpAll:\n";
            for my $svc (@services) {
                printf "  Service 0x%04X-0x%04X  %s\n", $svc->{start}, $svc->{end}, $svc->{uuid};
                my @chars = $self->list_characteristics_in_range($svc->{start}, $svc->{end});
                if (!@chars) {
                    print "    <no characteristics>\n";
                    next;
                }
                for my $c (@chars) {
                    printf "    value=0x%04X props=0x%02X uuid=%s\n",
                        $c->{value_handle}, $c->{props}, $c->{uuid};

                    # Read property bit 0x02.
                    if ($c->{props} & 0x02) {
                        my $raw = $self->read_char_by_handle($c->{value_handle});
                        if (defined $raw) {
                            my $hex = _hex_bytes($raw);
                            my $asc = _bytes_to_ascii($raw);
                            print "      raw:   $hex\n";
                            print "      ascii: $asc\n" if length($asc);
                        } else {
                            print "      raw:   <read failed>\n";
                        }
                    } else {
                        print "      raw:   <not readable>\n";
                    }
                }
            }
        }
    }

    if (defined $todo{read_handle}) {
        my $v = $self->read_char_by_handle($todo{read_handle});
        if (defined $v) {
            printf "Read 0x%04X:  %s\n", $todo{read_handle}, _hex_bytes($v);
        } else {
            printf STDERR "ERROR: Read handle 0x%04X failed\n", $todo{read_handle};
            $rc = 1;
        }
    }

    if (defined $todo{write_req_handle}) {
        if ($self->att_write_req_handle($todo{write_req_handle}, $todo{write_bytes})) {
            printf "Write req 0x%04X: %s\n", $todo{write_req_handle}, _hex_bytes($todo{write_bytes});
        } else {
            printf STDERR "ERROR: Write req handle 0x%04X failed\n", $todo{write_req_handle};
            $rc = 1;
        }
    }

    if (defined $todo{write_cmd_handle}) {
        if ($self->att_write_cmd_handle($todo{write_cmd_handle}, $todo{write_bytes})) {
            printf "Write cmd 0x%04X: %s\n", $todo{write_cmd_handle}, _hex_bytes($todo{write_bytes});
        } else {
            printf STDERR "ERROR: Write cmd handle 0x%04X failed\n", $todo{write_cmd_handle};
            $rc = 1;
        }
    }

    if (defined $todo{subscribe_handle}) {
        my $cccd = $todo{subscribe_handle} + 1;
        if ($self->att_write_request($cccd, pack('S<', 0x0001), 2.0)) {
            printf "Subscribed:   value=0x%04X cccd=0x%04X\n", $todo{subscribe_handle}, $cccd;
        } else {
            printf STDERR "ERROR: Subscribe failed for value handle 0x%04X (cccd 0x%04X)\n", $todo{subscribe_handle}, $cccd;
            $rc = 1;
        }
    }

    if ($todo{listen}) {
        my $target = defined $todo{notify_handle} ? sprintf('0x%04X', $todo{notify_handle}) : 'any';
        print "Listening:    handle=$target for $self->{notify_listen_sec}s\n";
        $self->listen_notifications($self->{notify_listen_sec}, $todo{notify_handle});
    }

    if ($todo{trace}) {
        my $target = defined $todo{notify_handle} ? sprintf('0x%04X', $todo{notify_handle}) : 'any';
        print "Tracing:      handle=$target for $self->{notify_listen_sec}s\n";
        print "TraceFile:    $todo{trace_file}\n";
        my $ok = $self->trace_notifications(
            seconds => $self->{notify_listen_sec},
            handle_filter => $todo{notify_handle},
            trace_file => $todo{trace_file},
            poll11 => $todo{trace_poll11},
            seed => $todo{trace_seed},
        );
        if (!$ok) {
            print STDERR "ERROR: trace failed\n";
            $rc = 1;
        }
    }

    if ($todo{fetch}) {
        my $data = $self->fetch_casio_data();
        if ($data) {
            print "Casio Watch Data\n";
            print "================\n";
            if (defined $data->{steps}) {
                printf "  Steps:        %u\n", $data->{steps};
            } else {
                print "  Steps:        <not decoded>\n";
            }
            printf "  StepsSource:  %s\n", $data->{steps_source} if defined $data->{steps_source};
            if (defined $data->{time_snapshot}) {
                printf "  TimeSnapshot: %s\n", $data->{time_snapshot};
            } else {
                print "  TimeSnapshot: <not decoded>\n";
            }
            printf "  TimeSource:   %s\n", $data->{time_source} if defined $data->{time_source};
            printf "  Device Info:  %s\n", $data->{device_info} if defined $data->{device_info};
            printf "  KeySound:     %s\n", $data->{key_sound_state} if defined $data->{key_sound_state};
            printf "  Status11Raw:  %s\n", $data->{status11_raw} if defined $data->{status11_raw} && $self->{debug};
            printf "  Status11Asc:  %s\n", _hex_to_ascii($data->{status11_raw}) if defined $data->{status11_raw} && $self->{debug};
            printf "  Status11Seq:  %s\n", $data->{status11_series} if defined $data->{status11_series} && $self->{debug};
            printf "  Status20Raw:  %s\n", $data->{raw20} if defined $data->{raw20} && $self->{debug};
            printf "  Status20Asc:  %s\n", _hex_to_ascii($data->{raw20}) if defined $data->{raw20} && $self->{debug};
            printf "  TimeStale20:  %s\n", $data->{time_stale} if defined $data->{time_stale} && $self->{debug};
            printf "  Steps20Cand:  %u\n", $data->{steps20_candidate} if defined $data->{steps20_candidate} && $self->{debug};
            printf "  Steps22Cand:  %u\n", $data->{steps22_candidate} if defined $data->{steps22_candidate} && $self->{debug};
            printf "  ExtraH11Raw:  %s\n", $data->{h11_raw} if defined $data->{h11_raw} && $self->{debug};
            printf "  ExtraH11Asc:  %s\n", _hex_to_ascii($data->{h11_raw}) if defined $data->{h11_raw} && $self->{debug};
            printf "  ExtraH14Raw:  %s\n", $data->{h14_raw} if defined $data->{h14_raw} && $self->{debug};
            printf "  ExtraH14Asc:  %s\n", _hex_to_ascii($data->{h14_raw}) if defined $data->{h14_raw} && $self->{debug};
            printf "  SyncH14Cnt:   %u\n", $data->{sync_h14_count} if defined $data->{sync_h14_count} && $self->{debug};
            printf "  SyncH14Max:   %u\n", $data->{sync_h14_max_len} if defined $data->{sync_h14_max_len} && $self->{debug};
            printf "  SyncH14Last:  %s\n", $data->{sync_h14_last} if defined $data->{sync_h14_last} && $self->{debug};
            printf "  SyncH14Asc:   %s\n", _hex_to_ascii($data->{sync_h14_last}) if defined $data->{sync_h14_last} && $self->{debug};
            printf "  Cmd15Raw:     %s\n", $data->{cmd_15_raw} if defined $data->{cmd_15_raw} && $self->{debug};
            printf "  Cmd15Asc:     %s\n", _hex_to_ascii($data->{cmd_15_raw}) if defined $data->{cmd_15_raw} && $self->{debug};
            printf "  Cmd16Raw:     %s\n", $data->{cmd_16_raw} if defined $data->{cmd_16_raw} && $self->{debug};
            printf "  Cmd16Asc:     %s\n", _hex_to_ascii($data->{cmd_16_raw}) if defined $data->{cmd_16_raw} && $self->{debug};
            printf "  Cmd18Raw:     %s\n", $data->{cmd_18_raw} if defined $data->{cmd_18_raw} && $self->{debug};
            printf "  Cmd18Asc:     %s\n", _hex_to_ascii($data->{cmd_18_raw}) if defined $data->{cmd_18_raw} && $self->{debug};
            printf "  Cmd1DRaw:     %s\n", $data->{cmd_1d_raw} if defined $data->{cmd_1d_raw} && $self->{debug};
            printf "  Cmd1DAsc:     %s\n", _hex_to_ascii($data->{cmd_1d_raw}) if defined $data->{cmd_1d_raw} && $self->{debug};
            printf "  Cmd1ERaw:     %s\n", $data->{cmd_1e_raw} if defined $data->{cmd_1e_raw} && $self->{debug};
            printf "  Cmd1EAsc:     %s\n", _hex_to_ascii($data->{cmd_1e_raw}) if defined $data->{cmd_1e_raw} && $self->{debug};
            printf "  Cmd26Raw:     %s\n", $data->{cmd_26_raw} if defined $data->{cmd_26_raw} && $self->{debug};
            printf "  Cmd26Asc:     %s\n", _hex_to_ascii($data->{cmd_26_raw}) if defined $data->{cmd_26_raw} && $self->{debug};
            printf "  Cmd28Raw:     %s\n", $data->{cmd_28_raw} if defined $data->{cmd_28_raw} && $self->{debug};
            printf "  Cmd28Asc:     %s\n", _hex_to_ascii($data->{cmd_28_raw}) if defined $data->{cmd_28_raw} && $self->{debug};
        } else {
            print "Fetch: failed to retrieve Casio watch data\n";
            $rc = 1;
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
    $self->{notif_queue} = [];
}

sub _queue_notification {
    my ($self, $handle, $att_data) = @_;
    push @{$self->{notif_queue}}, {
        handle => $handle,
        data   => $att_data,
        hex    => join('', map { sprintf '%02x', $_ } unpack('C*', $att_data)),
    };
}

sub _drain_notification_queue {
    my ($self) = @_;
    my @out = @{$self->{notif_queue} // []};
    $self->{notif_queue} = [];
    return @out;
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

sub att_write_request {
    my ($self, $handle, $value, $timeout) = @_;
    $timeout //= 2.0;
    my $rsp = $self->att_request(pack('C S< a*', ATT_WRITE_REQ, $handle, $value), $timeout);
    return unless defined $rsp && length($rsp) >= 1;
    return ord(substr($rsp, 0, 1)) == ATT_WRITE_RSP;
}

sub att_write_req_handle {
    my ($self, $handle, $bytes) = @_;
    return 0 unless defined($bytes);
    return $self->att_write_request($handle, $bytes, $self->{action_timeout}) ? 1 : 0;
}

sub att_write_cmd_handle {
    my ($self, $handle, $bytes) = @_;
    return 0 unless defined($bytes) && $self->{socket};
    my $pkt = pack('C S<', ATT_WRITE_CMD, $handle) . $bytes;
    my $w = syswrite($self->{socket}, $pkt);
    return defined($w) && $w == length($pkt) ? 1 : 0;
}

sub read_notification {
    my ($self, $timeout, $handle_filter) = @_;
    return undef unless $self->{socket};

    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, $timeout);
    return undef unless defined($n) && $n > 0;

    my ($response, $r) = ('');
    $r = sysread($self->{socket}, $response, 512);
    return undef unless defined($r) && $r > 0;

    my ($att_opcode, $notif_handle, $att_data);
    if (length($response) >= 4 && ord(substr($response, 0, 1)) == ATT_HANDLE_VALUE_NOTIF) {
        $att_opcode = ord(substr($response, 0, 1));
        $notif_handle = unpack('S<', substr($response, 1, 2));
        $att_data = substr($response, 3);
    } elsif (length($response) >= 8) {
        my $l2cap_cid = unpack('S<', substr($response, 2, 2));
        if ($l2cap_cid == 0x0004) {
            $att_opcode = ord(substr($response, 4, 1));
            if ($att_opcode == ATT_HANDLE_VALUE_NOTIF) {
                $notif_handle = unpack('S<', substr($response, 5, 2));
                $att_data = substr($response, 7);
            }
        }
    }

    return undef unless defined($att_opcode) && $att_opcode == ATT_HANDLE_VALUE_NOTIF;
    return undef unless defined($notif_handle) && defined($att_data);
    return undef if defined($handle_filter) && $notif_handle != $handle_filter;

    return {
        handle => $notif_handle,
        value  => $att_data,
    };
}

sub listen_notifications {
    my ($self, $seconds, $handle_filter) = @_;
    my $run_forever = !defined($seconds) || $seconds == 0;
    my $end = $run_forever ? undef : (time() + $seconds);

    while (!defined($end) || time() < $end) {
        my $notif = $self->read_notification(0.5, $handle_filter);
        next unless $notif;
        printf "Notify 0x%04X: %s\n", $notif->{handle}, _hex_bytes($notif->{value});
    }
}

sub trace_notifications {
    my ($self, %opt) = @_;
    my $seconds = $opt{seconds};
    my $handle_filter = $opt{handle_filter};
    my $trace_file = $opt{trace_file};
    my $poll11 = $opt{poll11} ? 1 : 0;
    my $seed = exists($opt{seed}) ? ($opt{seed} ? 1 : 0) : 1;

    my $run_forever = !defined($seconds) || $seconds == 0;
    my $end = $run_forever ? undef : (time() + $seconds);

    open(my $fh, '>', $trace_file) or return 0;
    print $fh "epoch_ms,handle,hex,ascii\n";

    # Enable known Casio notify channels for tracing.
    for my $cccd (0x000F, 0x0012, 0x0015, 0x001A) {
        my $ok = $self->att_write_request($cccd, pack('S<', 0x0003), 1.0);
        $self->debug(sprintf('Trace subscribe CCCD 0x%04X: %s', $cccd, $ok ? 'ok' : 'fail'));
    }

    my $handles = $self->find_casio_service();
    my $next_nudge = time() + 1.0;
    my $count = 0;

    # Seed the watch with the same command family used in fetch to provoke notifications.
    if ($seed && $handles) {
        for my $cmd (0x10, 0x11, 0x20, 0x13, 0x22) {
            $self->casio_send_command($cmd, $handles);
            select(undef, undef, undef, 0.05);
        }
    }

    while (!defined($end) || time() < $end) {
        if ($poll11 && $handles && time() >= $next_nudge) {
            $self->casio_send_command(0x11, $handles);
            $next_nudge = time() + 1.0;
        }

        my $notif = $self->read_notification(0.5, $handle_filter);
        next unless $notif;
        my $hex = lc(_hex_bytes($notif->{value}));
        $hex =~ s/\s+//g;
        my $ascii = _bytes_to_ascii($notif->{value});
        my $epoch_ms = int(time() * 1000);

        printf "Notify 0x%04X: %s\n", $notif->{handle}, _hex_bytes($notif->{value});
        print $fh join(',',
            _csv_escape($epoch_ms),
            _csv_escape(sprintf('0x%04X', $notif->{handle})),
            _csv_escape($hex),
            _csv_escape($ascii)
        ) . "\n";
        $count++;
    }

    close($fh);
    print "TraceCount:    $count\n";
    return 1;
}

sub casio_write_data_req {
    my ($self, $handle, $payload_hex) = @_;
    return 0 unless defined($payload_hex) && $payload_hex =~ /^[0-9a-fA-F]+$/;
    my $payload = pack('H*', $payload_hex);
    my $ok = $self->att_write_request($handle, $payload, 2.0);
    $self->debug(sprintf('WriteReq 0x%04X <= %s : %s', $handle, lc($payload_hex), $ok ? 'ok' : 'fail'));
    return $ok ? 1 : 0;
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

sub read_current_time {
    my ($self) = @_;
    my $handle = $self->find_char_value_handle_by_uuid16(0x2A2B);
    return undef unless defined $handle;

    my $raw = $self->read_char_by_handle($handle);
    return undef unless defined $raw && length($raw) >= 7;

    my $year = unpack('S<', substr($raw, 0, 2));
    my $mon  = ord(substr($raw, 2, 1));
    my $day  = ord(substr($raw, 3, 1));
    my $hour = ord(substr($raw, 4, 1));
    my $min  = ord(substr($raw, 5, 1));

    return undef if $year < 2000 || $year > 2099;
    return undef if $mon < 1 || $mon > 12;
    return undef if $day < 1 || $day > 31;
    return undef if $hour > 23 || $min > 59;

    return sprintf('%04d-%02d-%02d %02d:%02d', $year, $mon, $day, $hour, $min);
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

sub find_casio_service {
    my ($self) = @_;
    my $target_uuid = '26eb000d-b012-49a8-b1f8-394fb2032b0f';
    my @services = $self->list_primary_services();
    my ($svc) = grep { lc($_->{uuid}) eq $target_uuid } @services;
    return undef unless $svc;

    my @chars = $self->list_characteristics_in_range($svc->{start}, $svc->{end});
    my %handles;

    for my $c (@chars) {
        # Casio service UUIDs: 26eb002c... (command) and 26eb002d... (data)
        my $uuid_lower = lc($c->{uuid});
        if ($uuid_lower =~ /26eb002c/) {
            $handles{cmd_handle} = $c->{value_handle};
            $self->debug(sprintf('Found command handle: 0x%04X', $c->{value_handle}));
        }
        if ($uuid_lower =~ /26eb002d/) {
            $handles{data_handle} = $c->{value_handle};
            $self->debug(sprintf('Found data handle: 0x%04X', $c->{value_handle}));
        }
    }

    # Fallback by properties: write-only = command, notify/read = data
    unless ($handles{cmd_handle} && $handles{data_handle}) {
        $self->debug('UUID matching failed, trying property-based fallback');
        for my $c (@chars) {
            # 0x04 = Write, 0x02 = Read, 0x10 = Notify
            if (($c->{props} & 0x04) && !($c->{props} & 0x02) && !($c->{props} & 0x10)) {
                # Write-only = command
                $handles{cmd_handle} = $c->{value_handle};
                $self->debug(sprintf('Fallback: command handle 0x%04X (props=0x%02X)', $c->{value_handle}, $c->{props}));
            }
            if (($c->{props} & 0x10) || (($c->{props} & 0x02) && !($c->{props} & 0x04))) {
                # Notify or Read-only = data
                $handles{data_handle} = $c->{value_handle};
                $self->debug(sprintf('Fallback: data handle 0x%04X (props=0x%02X)', $c->{value_handle}, $c->{props}));
            }
        }
    }

    unless ($handles{cmd_handle} && $handles{data_handle}) {
        $self->debug('Could not locate Casio command and data handles');
        return undef;
    }

    return \%handles;
}

sub casio_send_command {
    my ($self, $byte, $handles) = @_;
    $handles ||= $self->find_casio_service();
    return undef unless $handles;

    # Send Write Command (0x52) to command handle with single byte
    my $req = pack('C S< C',
        ATT_WRITE_CMD,
        $handles->{cmd_handle},
        $byte
    );

    $self->debug(sprintf('Casio send cmd 0x%02X to handle 0x%04X', $byte, $handles->{cmd_handle}));
    return unless $self->{socket};
    my $w = syswrite($self->{socket}, $req);
    return defined($w) && $w == length($req);
}

sub casio_read_response {
    my ($self, $cmd_byte, $max_wait, $handles) = @_;
    $max_wait //= 2.0;
    $handles ||= $self->find_casio_service();
    return undef unless $handles;

    $self->debug(sprintf('Waiting for response to cmd 0x%02X on handle 0x%04X', $cmd_byte, $handles->{data_handle}));

    my $deadline = time() + $max_wait;
    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;

    while (time() < $deadline) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;

        my $n = select(my $rout = $rin, undef, undef, $remaining);
        next unless defined($n) && $n > 0;

        my ($response, $r) = ('');
        $r = sysread($self->{socket}, $response, 512);
        next unless defined($r) && $r > 0;

        my ($att_opcode, $notif_handle, $att_data);

        # Kernel L2CAP sockets often return raw ATT directly.
        if (length($response) >= 4 && ord(substr($response, 0, 1)) == ATT_HANDLE_VALUE_NOTIF) {
            $att_opcode = ord(substr($response, 0, 1));
            $notif_handle = unpack('S<', substr($response, 1, 2));
            $att_data = substr($response, 3);
        }
        # Fallback parser if framing includes L2CAP header.
        elsif (length($response) >= 8) {
            my $l2cap_cid = unpack('S<', substr($response, 2, 2));
            if ($l2cap_cid == 0x0004) {
                $att_opcode = ord(substr($response, 4, 1));
                if ($att_opcode == ATT_HANDLE_VALUE_NOTIF) {
                    $notif_handle = unpack('S<', substr($response, 5, 2));
                    $att_data = substr($response, 7);
                }
            }
        }

        next unless defined($att_opcode) && $att_opcode == ATT_HANDLE_VALUE_NOTIF;
        next unless defined($notif_handle);
        next unless defined($att_data) && length($att_data) > 0;

        my $resp_cmd = ord(substr($att_data, 0, 1));
        if ($notif_handle == $handles->{data_handle} && $resp_cmd == $cmd_byte) {
            $self->debug(sprintf('Got notification: cmd=0x%02X data=%s',
                $resp_cmd, join(' ', map { sprintf '%02X', $_ } unpack('C*', $att_data))));
            return $att_data;
        }

        # Preserve asynchronous notifications for later processing.
        $self->_queue_notification($notif_handle, $att_data);
    }

    $self->debug(sprintf('Timeout waiting for response to cmd 0x%02X', $cmd_byte));
    return undef;
}

sub casio_collect_notifications {
    my ($self, $seconds, $handles) = @_;
    $seconds //= 1.0;
    return () unless $self->{socket};

    my @out = $self->_drain_notification_queue();
    my $deadline = time() + $seconds;
    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;
    my $next_nudge = time() + 1.0;

    while (time() < $deadline) {
        if ($handles && time() >= $next_nudge) {
            # Nudge watch status stream during collection window.
            $self->casio_send_command(0x11, $handles);
            $next_nudge = time() + 1.0;
        }

        my $remaining = $deadline - time();
        last if $remaining <= 0;

        my $n = select(my $rout = $rin, undef, undef, $remaining);
        next unless defined($n) && $n > 0;

        my ($response, $r) = ('');
        $r = sysread($self->{socket}, $response, 512);
        next unless defined($r) && $r > 0;

        my ($att_opcode, $notif_handle, $att_data);

        if (length($response) >= 4 && ord(substr($response, 0, 1)) == ATT_HANDLE_VALUE_NOTIF) {
            $att_opcode = ord(substr($response, 0, 1));
            $notif_handle = unpack('S<', substr($response, 1, 2));
            $att_data = substr($response, 3);
        } elsif (length($response) >= 8) {
            my $l2cap_cid = unpack('S<', substr($response, 2, 2));
            if ($l2cap_cid == 0x0004) {
                $att_opcode = ord(substr($response, 4, 1));
                if ($att_opcode == ATT_HANDLE_VALUE_NOTIF) {
                    $notif_handle = unpack('S<', substr($response, 5, 2));
                    $att_data = substr($response, 7);
                }
            }
        }

        next unless defined($att_opcode) && $att_opcode == ATT_HANDLE_VALUE_NOTIF;
        next unless defined($notif_handle) && defined($att_data) && length($att_data) > 0;

        push @out, {
            handle => $notif_handle,
            data   => $att_data,
            hex    => join('', map { sprintf '%02x', $_ } unpack('C*', $att_data)),
        };
    }

    return @out;
}

sub _bcd_to_int {
    my ($v) = @_;
    return (($v >> 4) & 0x0F) * 10 + ($v & 0x0F);
}

sub _hex_to_ascii {
    my ($hex) = @_;
    return '' unless defined($hex) && $hex =~ /^[0-9a-fA-F]+$/ && length($hex) % 2 == 0;
    my $raw = pack('H*', $hex);
    $raw =~ s/[^\x20-\x7E]/./g;
    return $raw;
}

sub _bytes_to_ascii {
    my ($raw) = @_;
    return '' unless defined $raw;
    my $txt = $raw;
    $txt =~ s/[^\x20-\x7E]/./g;
    $txt =~ s/,/;/g;
    return $txt;
}

sub _csv_escape {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/"/""/g;
    return '"' . $v . '"';
}

sub _hex_bytes {
    my ($bytes) = @_;
    return '' unless defined $bytes;
    return join(' ', map { sprintf('%02X', $_) } unpack('C*', $bytes));
}

sub casio_decode_extra_notifications {
    my ($self, $data) = @_;
    my %decoded;

    # Handle 0x0011 notifications observed as compact stats payloads.
    if ($data->{h11_last} && length($data->{h11_last}) >= 4) {
        my $steps16 = unpack('S<', substr($data->{h11_last}, 2, 2));
        if ($steps16 > 0 && $steps16 < 500000) {
            $decoded{steps} = $steps16;
            $decoded{steps_source} = 'h11';
        }
    }

    # Handle 0x0014 notifications observed with BCD time triplet at bytes 3..5.
    if ($data->{h14_last} && length($data->{h14_last}) >= 6) {
        my $h = _bcd_to_int(ord(substr($data->{h14_last}, 3, 1)));
        my $m = _bcd_to_int(ord(substr($data->{h14_last}, 4, 1)));
        if ($h <= 23 && $m <= 59) {
            $decoded{time_snapshot} = sprintf('%02d:%02d', $h, $m);
            $decoded{time_source} = 'h14';
        }
    }

    return %decoded;
}

sub casio_extract_step_candidates {
    my ($payload) = @_;
    my @c;
    return @c unless defined($payload) && length($payload) >= 3;

    my @b = unpack('C*', $payload);
    for my $i (1 .. $#b - 1) {
        my $v16 = $b[$i] | ($b[$i+1] << 8);
        push @c, $v16 if $v16 > 0 && $v16 < 200000;
    }
    for my $i (1 .. $#b - 3) {
        my $v24 = $b[$i] | ($b[$i+1] << 8) | ($b[$i+2] << 16);
        push @c, $v24 if $v24 > 0 && $v24 < 200000;
    }

    return @c;
}

sub casio_decode_cmd15_16 {
    my ($self, $cmd15, $cmd16) = @_;
    my %out;

    my $s15;
    my $s16;

    if (defined($cmd15) && length($cmd15) >= 5 && ord(substr($cmd15, 0, 1)) == 0x15) {
        $s15 = unpack('n', substr($cmd15, 3, 2));
        $s15 = undef if $s15 <= 0 || $s15 > 200000;
    }

    if (defined($cmd16) && length($cmd16) >= 5 && ord(substr($cmd16, 0, 1)) == 0x16) {
        $s16 = unpack('n', substr($cmd16, 3, 2));
        $s16 = undef if $s16 <= 0 || $s16 > 200000;

        # cmd 0x16 payload observed with HH/MM at bytes 7/8 in cap3.
        if (length($cmd16) >= 9) {
            my $hh = ord(substr($cmd16, 7, 1));
            my $mm = ord(substr($cmd16, 8, 1));
            if ($hh <= 23 && $mm <= 59) {
                $out{time_snapshot} = sprintf('%02d:%02d', $hh, $mm);
                $out{time_source} = 'cmd_0x16';
            }
        }
    }

    if (defined $s16 && defined $s15) {
        # Keep only reasonably close values when both are present.
        if (abs($s16 - $s15) <= 1000) {
            $out{steps} = $s16;
            $out{steps_source} = 'cmd_0x16';
        }
    } elsif (defined $s16) {
        $out{steps} = $s16;
        $out{steps_source} = 'cmd_0x16';
    } elsif (defined $s15) {
        $out{steps} = $s15;
        $out{steps_source} = 'cmd_0x15';
    }

    return %out;
}

sub casio_run_sync_sequence {
    my ($self) = @_;

    # cap3 shows 0x0011 write requests driving large sync notifications on 0x0014.
    my @seq = qw(
        0005700000
        0405700000
        0011000000
        0411000000
        0000000000
        0400000000
    );

    my @captured;
    for my $hex (@seq) {
        $self->casio_write_data_req(0x0011, $hex);
        my @n = $self->casio_collect_notifications(0.35, undef);
        push @captured, @n if @n;
    }

    return @captured;
}

sub casio_decode_sync_h14 {
    my ($self, @sync_notifs) = @_;
    my %out;

    my @h14 = grep { $_->{handle} == 0x0014 } @sync_notifs;
    return %out unless @h14;

    my $last = $h14[-1];
    $out{sync_h14_count} = scalar(@h14);
    $out{sync_h14_last} = $last->{hex};

    my $max_len = 0;
    for my $n (@h14) {
        my $len = defined($n->{data}) ? length($n->{data}) : 0;
        $max_len = $len if $len > $max_len;

        # Short frame pattern seen in cap3: fa YY MM DD HH MM ...
        if (!defined($out{time_snapshot}) && $len >= 6) {
            my @b = unpack('C*', $n->{data});
            if ($b[0] == 0xFA) {
                my ($mo, $dd, $hh, $mm) = @b[2,3,4,5];
                if ($mo >= 1 && $mo <= 12 && $dd >= 1 && $dd <= 31 && $hh <= 23 && $mm <= 59) {
                    $out{time_snapshot} = sprintf('%02d:%02d', $hh, $mm);
                    $out{time_source} = 'sync_h14';
                }
            }
        }
    }

    $out{sync_h14_max_len} = $max_len;
    return %out;
}

sub casio_best_time_from_payloads {
    my ($self, @payloads) = @_;

    my @cand;
    my ($sec,$min,$hour) = localtime(time());

    for my $p (@payloads) {
        next unless defined($p) && length($p) >= 3;
        my @b = unpack('C*', $p);

        # Plain byte HH:MM search.
        for my $i (1 .. $#b - 1) {
            my ($h, $m) = ($b[$i], $b[$i+1]);
            if ($h <= 23 && $m <= 59) {
                my $delta = abs(($h*60 + $m) - ($hour*60 + $min));
                $delta = 1440 - $delta if $delta > 720;
                push @cand, { t => sprintf('%02d:%02d', $h, $m), delta => $delta };
            }
        }

        # BCD HH:MM search.
        for my $i (1 .. $#b - 1) {
            my $h = _bcd_to_int($b[$i]);
            my $m = _bcd_to_int($b[$i+1]);
            next unless $h <= 23 && $m <= 59;
            my $delta = abs(($h*60 + $m) - ($hour*60 + $min));
            $delta = 1440 - $delta if $delta > 720;
            push @cand, { t => sprintf('%02d:%02d', $h, $m), delta => $delta };
        }
    }

    return undef unless @cand;
    @cand = sort { $a->{delta} <=> $b->{delta} } @cand;
    return $cand[0]{t};
}

sub fetch_casio_data {
    my ($self) = @_;
    my $handles = $self->find_casio_service();
    unless ($handles) {
        $self->debug('Casio service not found');
        return undef;
    }

    $self->debug('Fetching Casio watch data...');

    # Enable notifications on the primary data CCCD (0x000F on known captures).
    my $cccd = $handles->{data_handle} + 1;
    my $cccd_ok = $self->att_write_request($cccd, pack('S<', 0x0003), 2.0);
    $self->debug(sprintf('Enable notifications on 0x%04X: %s', $cccd, $cccd_ok ? 'ok' : 'failed'));

    # App traces show additional notify channels are used as well.
    for my $extra_cccd (0x0012, 0x0015, 0x001A) {
        my $ok = $self->att_write_request($extra_cccd, pack('S<', 0x0003), 1.0);
        $self->debug(sprintf('Enable notifications on 0x%04X: %s', $extra_cccd, $ok ? 'ok' : 'skip'));
    }

    my %result;
    my %responses;

    # Run the sync-style sequence observed in cap3 on 0x0011/0x0014.
    my @sync_notifs = $self->casio_run_sync_sequence();
    my %sync_decoded = $self->casio_decode_sync_h14(@sync_notifs);
    for my $k (keys %sync_decoded) {
        $result{$k} = $sync_decoded{$k};
    }

    # Get device info
    $self->casio_send_command(0x10, $handles);
    my $info_resp = $self->casio_read_response(0x10, 2.5, $handles);
    $responses{0x10} = $info_resp if $info_resp;
    if ($info_resp && length($info_resp) >= 7) {
        # Response: 0x10 + MAC(6 reversed bytes) + ...
        my @mac = reverse unpack('C6', substr($info_resp, 1, 6));
        $result{device_info} = sprintf '%s at %s', 'ABL-100WE', join(':', map { sprintf '%02X', $_ } @mac);
    }

    # Try standard Current Time characteristic first (if exposed by firmware).
    my $ct = $self->read_current_time();
    if (defined $ct) {
        $result{time_snapshot} = $ct;
        $result{time_source} = 'gatt_2A2B';
    }

    # Poll 0x11 first: this appears to be the app's primary status query.
    $self->casio_send_command(0x11, $handles);
    my $status11 = $self->casio_read_response(0x11, 2.5, $handles);
    $responses{0x11} = $status11 if $status11;
    if ($status11 && length($status11) >= 13) {
        $result{status11_raw} = join('', map { sprintf '%02x', $_ } unpack('C*', $status11));
        # Replay app-style ack/config write to data handle to unlock live status stream.
        my $ack = $result{status11_raw};
        # Force flag byte to 0x80 as seen in app write requests.
        if (length($ack) >= 24) {
            substr($ack, 22, 2, '80');
            $self->casio_write_data_req($handles->{data_handle}, $ack);
        }
    }

    # Get current status block from 0x20.
    $self->casio_send_command(0x20, $handles);
    my $data_resp = $self->casio_read_response(0x20, 2.5, $handles);
    $responses{0x20} = $data_resp if $data_resp;
    if ($data_resp && length($data_resp) >= 20) {
        # Observed 0x20 layout on ABL-100WE:
        #   byte 1  = minute (e.g. 0x23 => 35)
        #   byte 13 = hour   (e.g. 0x17 => 23)
        #   bytes 8..10 = 24-bit step counter (LE)
        my $mm = ord(substr($data_resp, 1, 1));
        my $hh = ord(substr($data_resp, 13, 1));
        if (!defined($result{time_snapshot}) && $hh <= 23 && $mm <= 59) {
            my ($sec,$min,$hour) = localtime(time());
            my $delta = abs(($hh*60 + $mm) - ($hour*60 + $min));
            $delta = 1440 - $delta if $delta > 720;
            if ($delta <= 2) {
                $result{time_snapshot} = sprintf('%02d:%02d', $hh, $mm);
                $result{time_source} = 'cmd_0x20';
            } else {
                $result{time_stale} = sprintf('%02d:%02d', $hh, $mm);
            }
        }

        my $steps24 = unpack('V', substr($data_resp, 8, 4)) & 0x00FFFFFF;
        # 0x20 step field is not stable on all firmware variants; keep as debug only.
        $result{steps20_candidate} = $steps24;

        $result{raw20} = join('', map { sprintf '%02x', $_ } unpack('C*', $data_resp));
    }

    # Get key-sound status/state (observed via 0x1305.. / 0x1307.. in cap3).
    $self->casio_send_command(0x13, $handles);
    my $alarm_resp = $self->casio_read_response(0x13, 2.5, $handles);
    $responses{0x13} = $alarm_resp if $alarm_resp;
    if ($alarm_resp && length($alarm_resp) >= 3) {
        my $mode = ord(substr($alarm_resp, 1, 1));
        my $flag = ord(substr($alarm_resp, 2, 1));
        my $state = ($mode == 0x05) ? 'ENABLED'
                  : ($mode == 0x07) ? 'DISABLED'
                  : sprintf('UNKNOWN(mode=0x%02X flag=0x%02X)', $mode, $flag);
        $result{key_sound_state} = $state;

        # Mirror app behavior: echo cmd 0x13 payload back as a write request.
        my $ahex = join('', map { sprintf '%02x', $_ } unpack('C*', $alarm_resp));
        $self->casio_write_data_req($handles->{data_handle}, $ahex);
    }

    # Trigger status refresh repeatedly; some firmwares emit live data only after several polls.
    my @status11_series;
    for my $i (1 .. 4) {
        $self->casio_send_command(0x11, $handles);
        my $s11 = $self->casio_read_response(0x11, 1.2, $handles);
        if ($s11) {
            my $hex = join('', map { sprintf '%02x', $_ } unpack('C*', $s11));
            push @status11_series, $hex;
        }
        select(undef, undef, undef, 0.15);
    }

    my @extras = $self->casio_collect_notifications($self->{fetch_live_seconds}, $handles);
    $self->debug(sprintf('Collected %d async notifications', scalar(@extras)));
    my %extra;
    for my $n (@extras) {
        if ($n->{handle} == 0x0011) {
            $extra{h11_last} = $n->{data};
            $extra{h11_raw} = $n->{hex};
        } elsif ($n->{handle} == 0x0014) {
            $extra{h14_last} = $n->{data};
            $extra{h14_raw} = $n->{hex};
        }
    }

    my %decoded = $self->casio_decode_extra_notifications(\%extra);
    $result{steps} = $decoded{steps} if defined $decoded{steps};
    $result{time_snapshot} = $decoded{time_snapshot} if defined $decoded{time_snapshot};
    $result{steps_source} = $decoded{steps_source} if defined $decoded{steps_source};
    $result{time_source} = $decoded{time_source} if defined $decoded{time_source};
    $result{h11_raw} = $extra{h11_raw} if defined $extra{h11_raw};
    $result{h14_raw} = $extra{h14_raw} if defined $extra{h14_raw};
    $result{status11_series} = join(',', @status11_series) if @status11_series;

    # Best-effort fallback: some firmware responds to 0x22 with a compact status payload.
    if (!defined($result{steps}) || $result{steps} == 0) {
        $self->casio_send_command(0x22, $handles);
        my $alt_resp = $self->casio_read_response(0x22, 2.5, $handles);
        $responses{0x22} = $alt_resp if $alt_resp;
        if ($alt_resp && length($alt_resp) >= 12) {
            my $steps24 = unpack('V', substr($alt_resp, 8, 4)) & 0x00FFFFFF;
            # Keep as candidate only; this field is ambiguous on current watch firmware.
            $result{steps22_candidate} = $steps24;
        }
    }

    # Probe additional commands observed in app sessions for future decoding.
    for my $cmd (0x15, 0x16, 0x18, 0x1D, 0x1E, 0x26, 0x28) {
        $self->casio_send_command($cmd, $handles);
        my $resp = $self->casio_read_response($cmd, 1.8, $handles);
        $responses{$cmd} = $resp if $resp;
    }

    my %cmd1516 = $self->casio_decode_cmd15_16($responses{0x15}, $responses{0x16});
    if (defined $cmd1516{steps}) {
        $result{steps} = $cmd1516{steps};
        $result{steps_source} = $cmd1516{steps_source};
    }
    if (!defined($result{time_snapshot}) && defined $cmd1516{time_snapshot}) {
        $result{time_snapshot} = $cmd1516{time_snapshot};
        $result{time_source} = $cmd1516{time_source};
    }

    if ($self->{debug}) {
        for my $cmd (sort { $a <=> $b } keys %responses) {
            my $hex = join('', map { sprintf '%02x', $_ } unpack('C*', $responses{$cmd}));
            $result{sprintf('cmd_%02x_raw', $cmd)} = $hex;
        }
    }

    delete $result{steps} if defined($result{steps}) && $result{steps} == 0;

    return \%result;
}

sub debug {
    my ($self, $msg) = @_;
    print "  [DEBUG] $msg\n" if $self->{debug};
}

1;

package main;

sub parse_handle {
    my ($s) = @_;
    return undef unless defined $s;
    my $n;
    if ($s =~ /^0x([0-9A-Fa-f]{1,4})$/) {
        $n = hex($1);
    } elsif ($s =~ /^\d+$/) {
        $n = int($s);
    } else {
        return undef;
    }
    return undef if $n < 1 || $n > 0xFFFF;
    return $n;
}

sub parse_hex_bytes {
    my ($s) = @_;
    return undef unless defined $s;
    my $norm = $s;
    $norm =~ s/[\s:]//g;
    return undef if $norm eq '';
    return undef unless $norm =~ /^[0-9A-Fa-f]+$/;
    return undef if length($norm) % 2;
    my @bytes = map { hex($_) } ($norm =~ /(..)/g);
    return pack('C*', @bytes);
}

sub print_usage {
    print <<"EOF";
Usage: $0 -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (defaults to --identify --battery):
  --identify          Read Device Name (2A00) and Manufacturer (2A29)
  --battery           Read Battery Level (2A19)
  --services          List primary GATT services
  --chars             List characteristics for each primary service
  --dump-custom       Dump readable chars for Casio custom service
  --fetch             Fetch step counter and watch data (ABL-100WE proprietary)
    --read-handle H     Read raw value from ATT handle H
    --write-req-handle H --write-hex BYTES  Write using ATT Write Request
    --write-cmd-handle H --write-hex BYTES  Write using ATT Write Command
    --subscribe-handle H Enable notifications by writing 0x0001 to H+1 (CCCD)
    --listen            Print notifications for --notify-listen-sec seconds
    --notify-handle H   Filter --listen output to this value handle
    --trace             Capture notifications to trace file (CSV)

Required:
  -d, --device ADDR   BLE MAC address

Options:
  --addr-type TYPE    public|random (default: public)
  --connect-timeout S Connect timeout seconds (default: 8)
    --listen-seconds S  Keep retrying connect for S seconds (watch-initiated mode)
  --fetch-live-seconds S  Seconds to collect async live notifications (default: 6)
    --response-timeout-ms MS  ATT response timeout in ms (default: 2500)
    --notify-listen-sec S  Notification listen duration for --listen (default: 10, 0=indefinite)
    --trace-file FILE   CSV output file for --trace (default: casio_trace.log)
    --trace-poll11      Send periodic 0x11 commands during --trace (default: on)
    --no-trace-poll11   Disable periodic 0x11 commands during --trace
    --trace-seed        Send seed command burst at trace start (default: on)
    --no-trace-seed     Disable seed command burst at trace start
    --write-hex BYTES   Hex bytes e.g. "AA BB 01 02" or "AABB0102"
  --action-timeout S  ATT read timeout seconds (default: 6)
  -v, --debug         Verbose output
  -h, --help          Show this help

Examples:
  $0 -d EB:5E:BB:56:29:37 --addr-type public --identify --battery
  $0 -d EB:5E:BB:56:29:37 --addr-type public --services
  $0 -d EB:5E:BB:56:29:37 --addr-type public --chars
  $0 -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --fetch
  $0 -d EB:5E:BB:56:29:37 --addr-type random --listen-seconds 45 --fetch -v
  $0 -d EB:5E:BB:56:29:37 --addr-type public --fetch --battery --identify
    $0 -d EB:5E:BB:56:29:37 --read-handle 0x000E
    $0 -d EB:5E:BB:56:29:37 --subscribe-handle 0x000E --listen --notify-listen-sec 20
    $0 -d EB:5E:BB:56:29:37 --write-req-handle 0x000E --write-hex "11 0F 0F"
    $0 -d EB:5E:BB:56:29:37 --addr-type random --trace --notify-listen-sec 15 --trace-file casio_trace_after_walk.csv -v
    $0 -d EB:5E:BB:56:29:37 --addr-type random --trace --notify-handle 0x0014 --notify-listen-sec 20 -v
EOF
}
