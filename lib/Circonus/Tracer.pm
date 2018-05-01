package Circonus::Tracer;

use strict;
use warnings;

# Generic includes
use Carp;
use Data::Dumper;
use Math::BigInt;
use Socket qw/PF_INET SOCK_DGRAM pack_sockaddr_in inet_aton sockaddr_in inet_ntoa/;
use Time::HiRes qw/gettimeofday tv_interval/;
use URI;

# Turn off CIRCONUS_TRACER if required modules can't be loaded.  This
# has to be done in a BEGIN block since CIRCONUS_TRACER is tested in
# another BEGIN block later.
BEGIN {
    eval 'use Logger::Fq';
    if ($@) {
        warn "Circonus::Tracer requested, but Logger::Fq missing\n";
        $ENV{CIRCONUS_TRACER} = 0;
    }

    # The thrift support
    eval q/
        use Thrift;
        use Thrift::Socket;
        use Thrift::BinaryProtocol;
        use Thrift::BufferedTransport;
        use Thrift::MemoryBuffer;
        use Zipkin::Types;
    /;

    if ($@) {
        warn "Disabling Circonus::Tracer: $@\n";
        $ENV{CIRCONUS_TRACER} = 0;
    }
}

# This is somewhat evil... We're going
# to lift constants from the Zipkin::AnnotationType
# So that we don't need to use that and thus need Thrift
use constant BOOL => 0;
use constant BYTES => 1;
use constant I16 => 2;
use constant I32 => 3;
use constant I64 => 4;
use constant DOUBLE => 5;
use constant STRING => 6;
use constant LOCAL_CURLOPT_HTTPHEADER => 10023;
use constant LOCAL_CURLINFO_EFFECTIVE_URL => 0x100000 + 1;
use constant LOCAL_CURLINFO_PRIVATE => 0x100000 + 21;
use constant LOCAL_CURLINFO_HTTP_CODE => 0x200000 + 2;

=head1 NAME

Circonus::Tracer - Zipkin Tracer

=head1 DESCRIPTION

  # No user servicable parts contained within

=head1 SYNOPSIS

This  implements a Zipkin client http://twitter.github.io/zipkin/ for Circonus
perl code.  This provides a generic facility for wrapping unwitting perl
functions and methods with Zipkin spans and annotations.

Zipkin prescribes something rather ineffeicient, stupid and a bit painful.
First, it uses Thrift to code the Span information that it sends up.  While
this encoding format isn't stellar, it is workable.  However, Zipkin dictates
that the Thrift-encoded message be sent via Scribe (which is Thrift). Scribe
messages must be strings, which means that one has to opaquely encode the
original Thrift message in base64 (inefficient and stupid) and then send it
via a synchronous protocol (painful).

In our system we *never* want to block on logging.  For this we decouple the
Zipkin Thrift-ecnoded spans (still in binary) from the Scribing of said spans.
We leverage Fq for this.  Logger::Fq provides a completely non-blocking,
binary-safe logging mechanism via Fq.  Obviously, we don't have guaranteed
deliver, but since we can't block, this is actually the best we can do anyway.

The system is designed to instrument remote procedure calls.

=head1 USAGE

Add C<PerlSetEnv CIRCONUS_TRACER 1> to your Apache config.

Add C<use Circonus::Tracer;> to your startup.pl file.

=head1 FUNCTIONS

=head2 tracer_wrap($function, %options)

See Extnding section.

=head2 annotate($key [, $value [, $type [, $endpoint ] ] ])

Add an annotation (Zipkin BinaryAnnotation) to the current span.

=cut

our @EXPORT_OK = qw/
    annotate
    new_trace
    finish_trace
    live_span
    tracer_wrap
    add_trace_cleaner
/;

# This may get reset to $ENV{CIRCONUS_TRACER_SERVICE_NAME} in
# mungo_start_trace().
my $service_name = $ENV{MOD_PERL} && $ENV{MOD_PERL} =~ m!^mod_perl/!
    ? 'mod_perl'
    : 'perl';

my $trace_id;
my @live_span;
my @span_ids;

my @cleanup_tasks;
my $IMPLICIT_TRACE;

my $TRACE_RE => qr/^(?:[1-9]\d*|0x[0-9a-zA-Z]{1,16})$/;

sub uint64 {
    return Math::BigInt->new(shift)->bstr();
}

sub new_trace_id {
    return uint64("0x" . sprintf("%02x" x 8, int(rand(127)), map { int(rand(255)) } (1..7)));
}

sub ts_to_us {
    my $ts = shift;
    if(!$ts) {
        $ts = [gettimeofday];
    }
    if(ref($ts) eq 'ARRAY') {
        $ts = $ts->[0] * 1000000 + $ts->[1];
    }
    return $ts;
}

sub suggest_name {
    return "script: $main::0";
}

sub mkann {
    my $type = shift;
    my $duration = shift;
    my $ts = shift;
    my $endpoint = shift;
    $ts = ts_to_us($ts);
    my $ann = {
        value => $type,
        timestamp => 0 + $ts,
    };
    $ann->{duration} = $duration if(defined($duration));
    $ann->{host} = bless $endpoint, 'Zipkin::EndPoint' if(defined($endpoint));
    $ann->{host} ||= default_endpoint();
    return bless $ann, 'Zipkin::Annotation';
}

sub new_trace {
    my $name = shift || suggest_name();

    $trace_id = @_ ? uint64(shift) : new_trace_id();

    @live_span = ();

    @span_ids = grep /$TRACE_RE/, @_;
    @span_ids = $trace_id unless @span_ids;

    my $now = ts_to_us();

    $_ = bless {
        id        => uint64($_),
        trace_id  => $trace_id,
        timestamp => $now,
    }, 'Zipkin::Span' for @span_ids;

    $span_ids[0]->{host} = default_endpoint();
    $span_ids[0]->{name} = $name;
    $span_ids[0]->{annotations} = [ mkann('sr', undef, $now) ];
}

BEGIN {
    # Cache IP address.
    my $ipint;

    sub default_endpoint {
        $ipint ||= unpack 'N', pack 'C4', split /\./, my_ip();

        return bless {
            ipv4 => $ipint,
            port => $ENV{SERVER_PORT} || 0,
            service_name => $service_name,
        }, 'Zipkin::Endpoint';
    }
}

# Get IP address.
sub my_ip {
    my $tgt_ip = "8.8.8.8";
    socket(my $s, PF_INET, SOCK_DGRAM, 17); # 17 -> UDP
    connect($s, pack_sockaddr_in(53, inet_aton($tgt_ip)));
    my $mysockaddr = getsockname($s);
    my ($port, $myaddr) = sockaddr_in($mysockaddr);
    return inet_ntoa($myaddr);
}

BEGIN {
    if ($ENV{CIRCONUS_TRACER}) {
        my $n_trace_id = '';
        $n_trace_id = $ENV{'B3_TRACEID'} if($ENV{'B3_TRACEID'});
        my $n_parent_span_id = $ENV{'B3_PARENTSPANID'} || '';
        my $n_span_id = $ENV{'B3_SPANID'} || '';
        if(exists($ENV{SHLVL})) {
            $IMPLICIT_TRACE = 1;
            $n_trace_id ||= new_trace_id();
        }
    
        if ($n_trace_id =~ $TRACE_RE) {
            new_trace(undef, $n_trace_id, $n_parent_span_id, $n_span_id);
        }
    }
}

sub finish_trace {
    my $span = shift @span_ids;

    if (exists($span->{name})) {
        push @{$span->{annotations}}, mkann("ss", undef, undef);
        publish_span($span);
    }

    $trace_id = undef;
    @live_span = ();
    @span_ids = ();

    $_->() for @cleanup_tasks;
}

sub live_span {
    return $live_span[0];
}

sub setenv {
    delete $ENV{B3_TRACEID};
    delete $ENV{B3_SPANID};
    delete $ENV{B3_PARENTSPANID};

    if (my $span = $live_span[0]) {
        $ENV{B3_TRACEID} = $span->{trace_id};
        $ENV{B3_SPANID} = $span->{id};
        $ENV{B3_PARENTSPANID} = $span->{parent_id}
            if exists $span->{parent_id};
    }
}

END {
    if ($ENV{CIRCONUS_TRACER} && $IMPLICIT_TRACE && @span_ids) {
        finish_trace();
        eval {
            Logger::Fq::drain(2);
            sleep(1);
        };
    }
}

sub line_number {
    my @parts = caller(2);
    return { key => "line", value => "$parts[1]:$parts[2]" };
}
sub coerce_bin_annotation {
    my $bin = shift;
    return undef unless (ref($bin) eq 'HASH' && $bin->{key} && exists($bin->{value}));
    eval {
        my $a = $bin->{annotation_type} || 'STRING';
        if($a eq 'BOOL') { $bin->{annotation_type} = BOOL; $bin->{value} = !!$bin->{value}}
        elsif($a eq 'BYTES') { $bin->{annotation_type} = BYTES; }
        # The following appears to be a travesty that cannot be undone
        elsif($a eq 'I16') {
            $bin->{annotation_type} = I16;
            $bin->{value} = pack("n", int($bin->{value}));
        }
        elsif($a eq 'I32') {
            $bin->{annotation_type} = I32;
            $bin->{value} = pack("N", int($bin->{value}));
        }
        elsif($a eq 'I64') {
            $bin->{annotation_type} = I64;
            my ($bp, $lp) = (int($bin->{value}) >> 32, int($bin->{value}) & 0xffffffff);
            $bin->{value} = pack("NN", $bp, $lp);
        }
        elsif($a eq 'DOUBLE') {
            $bin->{annotation_type} = DOUBLE;
            $bin->{value} = pack("d>", 1.0 * $bin->{value});
        }
        else { $bin->{annotation_type} = STRING; }
        if(exists($bin->{host})) {
            $bin->{host} = bless $bin->{host}, 'Zipkin::Endpoint';
        }
    };
    return undef if($@);
    return bless $bin, 'Zipkin::BinaryAnnotation';
}

sub simple_wrap {
    my $old_name = shift;
    my $pre = shift || [];
    my $post = shift || [];

    my $typeglob = (ref $old_name || $old_name =~ /::/)
        ? $old_name
        : caller()."::$old_name";
    my $old_func;
    {
        no strict 'refs';
        $old_func = ref $typeglob eq 'CODE' && $typeglob
            || *$typeglob{CODE}
            || croak "Can't wrap non-existent subroutine $typeglob";
    }
    my $u_func = sub {
        my $wantarray = wantarray;
        my @results;

        foreach my $pre_run (@$pre) { $pre_run->(\@_); }
        eval {
            if ($wantarray) {
                @results = &$old_func;
            } else {
                $results[0] = &$old_func;
            }
        };
        foreach my $post_run (@$post) { $post_run->(\@_, \@results); }

        my $exception = $@;
        die $exception if $exception;
        return @results if $wantarray;
        return $results[0];
    };
    no warnings 'syntax';
    no warnings 'redefine';
    no strict 'refs';
    *{$typeglob} = $u_func;
}
sub tracer_wrap {
    my $old_name = shift;
    my %args = @_;
    my $newspan = $args{newspan} || 0;
    my $floatingspan = $args{floatingspan} || 0;
    my $preamble = $args{preamble};
    my $postamble = $args{postamble};
    my $pre_runs = $args{pre_bins};
    $pre_runs = [ $pre_runs ] unless(ref($pre_runs) eq 'ARRAY');
    my $post_runs = $args{post_bins};
    $post_runs = [ $post_runs ] unless(ref($post_runs) eq 'ARRAY');
    my $name = $args{name} || "$old_name";
    my $wants_start = exists($args{wants_start}) ? $args{wants_start} : 1;
    my $wants_end = exists($args{wants_end}) ? $args{wants_end} : 1;

    my $typeglob = (ref $old_name || $old_name =~ /::/)
        ? $old_name
        : caller()."::$old_name";
    my $old_func;
    {
        no strict 'refs';
        $old_func = ref $typeglob eq 'CODE' && $typeglob
            || *$typeglob{CODE}
            || croak "Can't wrap non-existent subroutine $typeglob";
    }
    my $u_func = sub {
        my $wantarray = wantarray;
        my ($span, @results, $start_time, $duration_us);

        $span = undef;
        if($preamble) { $span = $preamble->($trace_id, \@_); }
        if($trace_id) {
            if($span) {
            }
            elsif($newspan) {
                $span = bless {
                    id => new_trace_id(),
                    name => (ref($name) eq 'CODE')  ? $name->(@_) : $name,
                    trace_id => $trace_id,
                    host => default_endpoint(),
                    annotations => [],
                    binary_annotations => []
                }, 'Zipkin::Span';
                $span->{parent_id} = $span_ids[0]->{id} if(@span_ids > 0);
                unshift @span_ids, $span unless($floatingspan);
            } else {
                $span = $span_ids[0];
                $span->{annotations} ||= [];
                $span->{binary_annotations} ||= [];
            }
            push @{$span->{annotations}}, mkann("cs", undef, $start_time) if ($newspan && $wants_start);

            foreach my $pre_run (@$pre_runs) {
                if(ref($pre_run) eq 'CODE') {
                    push @{$span->{binary_annotations}},
                        grep { ref($_) eq 'Zipkin::BinaryAnnotation' }
                            map { coerce_bin_annotation($_) } $pre_run->($span, \@_);
                }
            }
            $start_time = [gettimeofday];
        }

        unshift @live_span, $span;
        setenv();
        eval {
            if ($wantarray) {
                @results = &$old_func;
            } else {
                $results[0] = &$old_func;
            }
        };
        my $exception = $@;
        shift @live_span;
        setenv();
   
        if($span && $span->{trace_id}) {
            my $end_time = [gettimeofday];
            push @{$span->{annotations}}, mkann("cr", undef, $end_time) if ($newspan && $wants_end);
            $duration_us = int(tv_interval( $start_time, $end_time ) * 1000000);
            foreach my $post_run (@$post_runs) {
                if(ref($post_run) eq 'CODE') {
                    push @{$span->{binary_annotations}},
                        grep { ref($_) eq 'Zipkin::BinaryAnnotation' }
                            map { coerce_bin_annotation($_) } $post_run->($span, \@_, \@results);
                }
            }
            if($newspan && ($floatingspan || @span_ids > 1)) {
                shift @span_ids unless($floatingspan);
                publish_span($span) if($wants_end);
            }
        }
        $postamble->($trace_id, \@_, \@results) if($postamble);

        die $exception if $exception;
        return @results if $wantarray;
        return $results[0];
    };
    no warnings 'syntax';
    no warnings 'redefine';
    no strict 'refs';
    *{$typeglob} = $u_func;
}

=head1 IMPLEMENTATIONS

=cut

BEGIN {
    my $logger_pid = 0;
    my $logger;

    sub open_logger {
        $ENV{CIRCONUS_TRACER} or return;

        if ($logger_pid != $$) {
            $logger_pid = $$;
            $logger = Logger::Fq->new({ exchange => "logging" });
        }

        return $logger;
    }
}

if($ENV{CIRCONUS_TRACER}) {

=head2 Mungo and Mungo::Quiet

We wrap the C<handler> method and start a new trace.

We add annotations: http.uri, http.hostname, http.method, http.status.

=cut

    eval q{use Mungo; use Mungo::Quiet;};
    unless($@) {
        tracer_wrap("Mungo::Quiet::handler",
                    preamble => \&mungo_start_trace, postamble => \&mungo_end_trace,
                    pre_bins => \&apache_pre, post_bins => \&apache_post);
        tracer_wrap("Mungo::handler",
                    preamble => \&mungo_start_trace, postamble => \&mungo_end_trace,
                    pre_bins => \&apache_pre, post_bins => \&apache_post);
    }

=head2 DBI

We wrap DBI::st and DBI::db to track statement "execute" and "do" methods.

We add annotations: sql.statement.

=cut

    eval q{use DBI;};
    unless($@) {
        tracer_wrap("DBI::st::execute", newspan => 1,
                    name => dbi_namer("DBI::st->execute"),
                    pre_bins => [\&line_number, \&dbi_pre] );
        tracer_wrap("DBI::db::do", newspan => 1,
                    name => dbi_namer("DBI::db->do"),
                    pre_bins => [\&line_number, \&dbi_pre] );
    }

=head2 Redis::hiredis

We wrap the commands from Redis.

=cut

    eval q{use Redis::hiredis;};
    unless($@) {
        tracer_wrap("Redis::hiredis::command", newspan => 1, name => sub { "Redis::hiredis::$_[1]" });
    }

=head2 WWW::Curl

We wrap WWW::Curl::Easy in the simple sense and use a more complex concept
of non-heirarchical (or floating) spans to support WWW::Curl::Multi.

We add annotations: http.uri, http.hostname, http.status.

Additionally, we "manipulate" requests going out to append X-B3-* headers so
that downstream HTTP services can report on the spans.

=cut

    eval q{use WWW::Curl::Easy; use WWW::Curl::Multi;};
    unless($@) {
        simple_wrap("WWW::Curl::Easy::setopt", [ \&curl_header_hack ]);
        tracer_wrap("WWW::Curl::Easy::perform", newspan => 1, pre_bins => [\&line_number, \&curl_pre],
                    post_bins => [\&curl_post] );
        tracer_wrap("WWW::Curl::Multi::add_handle", newspan => 1, floatingspan => 1, wants_end => 0,
                    pre_bins => [\&line_number,\&curlm_add_handle_pre] );
        tracer_wrap("WWW::Curl::Multi::info_read", wants_start => 0, wants_end => 0,
                    postamble => \&curlm_info_read_postamble);
    }
}

sub add_trace_cleaner {
    push @cleanup_tasks, @_;
}

my %curl_hdr_hacks;
sub curl_header_hack {
    my $args = shift;
    my $curl = $args->[0];
    if($args->[1] == LOCAL_CURLOPT_HTTPHEADER) {
        my @copy = @{$args->[2]};
        $curl_hdr_hacks{$curl} = \@copy;
    }
}
my %curlm_handles = ();
add_trace_cleaner(sub { %curlm_handles = (); });
sub curlm_info_read_postamble {
    my $tid = shift;
    my $args = shift;
    my $results = shift;
    my $curlm = $args->[0];
    my $id = $results->[0];
    return unless $id;
    my $info = $curlm_handles{$curlm}->{$id};
    return if(!$info);
    my $curl = $info->{curl};
    my $span = $info->{span};
    return unless $curl;
    delete $curlm_handles{$curlm}->{$id};
    push @{$span->{annotations}}, mkann("cr", undef, undef);
    push @{$span->{binary_annotations}},
        grep { ref($_) eq 'Zipkin::BinaryAnnotation' }
            map { coerce_bin_annotation($_) } curl_post($span, [ $curl ]);
    publish_span($span);
}
sub curl_header_fixup {
    my $curl = shift;
    my $span = shift;
    my $hdrs = $curl_hdr_hacks{$curl} || [];
    delete($curl_hdr_hacks{$curl});
    my $X_trace_id = Math::BigInt->new($span->{trace_id})->as_hex();
    my $X_span_id = Math::BigInt->new($span->{id})->as_hex();
    push @$hdrs, "X-B3-TraceId: $X_trace_id",
                 "X-B3-SpanId: $X_span_id";
    if(exists($span->{parent_id})) {
      my $X_parent_span_id = Math::BigInt->new($span->{parent_id})->as_hex();
      push @$hdrs, "X-B3-ParentSpanId: $X_parent_span_id";
    }
    $curl->setopt(LOCAL_CURLOPT_HTTPHEADER, $hdrs);
}
sub curlm_add_handle_pre {
    my $span = shift;
    my $args = shift;
    my $curlm = $args->[0];
    my $curl = $args->[1];
    my $id = $curl->getinfo(LOCAL_CURLINFO_PRIVATE);
    $curlm_handles{$curlm}->{$id} = { curl => $curl, span => $span };

    # Add cross-service tracing headers
    eval { curl_header_fixup($curl, $span); };
    return;
}
sub curl_pre {
    my $span = shift;
    my $args = shift;
    my $curl = $args->[0];

    # Add cross-service tracing headers
    eval { curl_header_fixup($curl, $span); };
    return;
}
sub curl_post {
    my $span = shift;
    my $args = shift;
    my $curl = $args->[0];
    my $url = $curl->getinfo(LOCAL_CURLINFO_EFFECTIVE_URL);
    my $hostname = undef;
    eval {
        my $u = URI->new($url);
        $hostname = $u->host();
        $url = $u->path();
    };
    my $code = $curl->getinfo(LOCAL_CURLINFO_HTTP_CODE);
    my @bins = ( { key => "http.uri", value => $url },
               { key => "http.status", value => $code } );
    push @bins, { key => "http.hostname", value => $hostname }
        if(defined($hostname));
    return @bins;
}
sub dbi_namer {
    my $method = shift;
    return sub {
        my $dbi_genh = shift;
        my $db = undef;
        $db = $dbi_genh if(ref($dbi_genh) eq 'DBI::db');
        $db = $dbi_genh->{Database} if(ref($dbi_genh) eq 'DBI::st');
        my $connstr = $db->get_info(2);
        my $name = $method;
        if($connstr =~ /^dbi:([^:]+)/i) {
            my $dbi_driver = $1;
            $name =~ s/^DBI/DBI($dbi_driver)/;
        }
        return $name;
    };
}
sub dbi_pre {
    my $span = shift;
    my $args = shift;
    my $dbi_genh = $args->[0];
    return ( { key => "sql.statement", value => $dbi_genh->{Statement} } );
}
sub apache_pre() {
    my $span = shift;
    my $args = shift;
    my $r = $args->[0];
    return ( { key => "http.hostname", value => $r->hostname() },
             { key => "http.uri", value => $r->uri() },
             { key => "http.method", value => $r->method() } );
}

sub apache_post() {
    my $span = shift;
    my $args = shift;
    my $r = $args->[0];
    return ( { key => "http.status", value => $r->status() } );
}

sub mungo_start_trace() {
    my $tid = $_[0];
    my $args = $_[1];
    return undef if($tid);
    my $r = $args->[0];

    my $name = $r->uri();
    my $htid = $r->headers_in->{'x-b3-traceid'} || '';

    $service_name = $ENV{CIRCONUS_TRACER_SERVICE_NAME} || 'mod_perl';

    if ($htid =~ $TRACE_RE) {
        new_trace($name, $htid,
                  $r->headers_in->{'x-b3-parentspanid'},
                  $r->headers_in->{'x-b3-spanid'});
    } else {
        new_trace($name);
    }
    return undef;
}

sub mungo_end_trace() {
    finish_trace();
}

sub publish_span {
    my $logger = open_logger() or return;

    my $span = shift;

    eval {
        my $mem = Thrift::MemoryBuffer->new();
        my $proto = Thrift::BinaryProtocol->new($mem);
        $span->write($proto);
        my $payload = $mem->getBuffer();

        if (0) { # Debugging Thrift
            my $oproto = Thrift::BinaryProtocol->new($mem);
            my $ospan = bless {}, 'Zipkin::Span';
            $ospan->read($oproto);
            print STDERR Dumper($ospan);
        }

        $logger->log("zipkin.thrift.$span->{trace_id}", $payload);
    };

    warn $@ if $@;
}

sub annotate($$;$$) {
    if(@span_ids) {
        my $key = shift;
        my $value = shift;
        my $type = shift;
        my $endpoint = shift;
        my $o = { key => $key, value => $value };
        $o->{annotation_type} = $type if($type);
        $o->{host} = $endpoint if($endpoint);
        push @{$span_ids[0]->{binary_annotations}},
            grep { ref($_) eq 'Zipkin::BinaryAnnotation' }
                ( coerce_bin_annotation($o) );
    }
}

# return true

=head1 EXTENDING

All extensions should leverage the C<tracer_wrap> function.

=head3 tracer_wrap($function, %options)

C<%options> may include

=over

=item name => $scalar [default: "$function"]

=item name => sub(\@_) { return $scalar; }

A name or naming function for the span.

=item newspan => 1 [default: 0]

This will cause a new span to be created and pushed into the heirrchy.
The span will have a parent of the current span and a new span id assigned.
As this is designed for talking to other distributed components, the
Zipkin C<CLIENT_SEND> and C<CLIENT_RECIEVE> annotations will be added
automatically (unless C<wants_start> or C<wants_end> are disabled).

=item floatingspan => 1 [default: 0]

If floatingspan is enabled, new spans are not added to the heirarchy.
They "float" and you are responsible for them.

=item wants_end => 0 [default: 1]

=item wants_start => 0 [default: 1]

Optionally disables the C<CLIENT_SEND> and C<CLIENT_RECIEVE> annotations
on new spans.

=item preamble => sub($trace_id, \@_) { return $span; } [default: undef]

Run some code before any new span is created and optionall create and
return that span.

=item postamble => sub($trace_id, \@_, \@rv)

Run some code when we're finished the wrapping.

=item pre_bins => [ sub($span, \@_) {return @bins;} [, ... ]]]

=item post_bins => [ sub($span, \@_, \@rv) {return @bins;} [, ... ]]]

A list of functions that return a list of Zipkin BinaryAnnotations.
C<pre_bins> are run before the wrapped function executes and C<post_bins>
are run after the function executes (with the return values as C<@rv>).

Annotations are a hash containing "key", "value", and optionally an
"annotation_type" of ("BOOL", "BYTES", "I16", "I32", "I64", "DOUBLE", or
"STRING") and an optional "host" that is a C<Zipkin::Endpoint>.  The
host will default to a reasonable Endpoint and should not be provided
unless you are reporting a annotation on behalf of another.

=item add_trace_cleaner( sub )

Adds a cleanup handler that will run when all traces finish. Do not
register per-trace, only globally.

=back

=head1 CAVEATS AND BUGS

This is all black magic (as is most of Perl anyway).

This will not work with a threaded perl.

Due to the asynchronous nature of C<Logger::Fq>, processes that exit
(like CLI tools and regular scripts) will notice between one and two
seconds of lag time (sleeping) on exit where we allow time for the
Logger::Fq asynchronous backlog to be sent out.  Entirely impoerfect,
but usually "good enough."  This has no noticeable effect on long-running
perl processes (most specifically mod_perl apps).

=cut

1;
