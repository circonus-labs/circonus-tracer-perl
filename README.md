# NAME

Circonus::Tracer - Zipkin Tracer

# DESCRIPTION

    # No user servicable parts contained within

# SYNOPSIS

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

In our system we \*never\* want to block on logging.  For this we decouple the
Zipkin Thrift-ecnoded spans (still in binary) from the Scribing of said spans.
We leverage Fq for this.  Logger::Fq provides a completely non-blocking,
binary-safe logging mechanism via Fq.  Obviously, we don't have guaranteed
deliver, but since we can't block, this is actually the best we can do anyway.

The system is designed to instrument remote procedure calls.

# USAGE

Add `PerlSetEnv CIRCONUS_TRACER 1` to your Apache config.

Add `use Circonus::Tracer;` to your startup.pl file.

# FUNCTIONS

## tracer\_wrap($function, %options)

See Extnding section.

## annotate($key \[, $value \[, $type \[, $endpoint \] \] \])

Add an annotation (Zipkin BinaryAnnotation) to the current span.

# IMPLEMENTATIONS

## Mungo and Mungo::Quiet

We wrap the `handler` method and start a new trace.

We add annotations: http.uri, http.hostname, http.method, http.status.

## DBI

We wrap DBI::st and DBI::db to track statement "execute" and "do" methods.

We add annotations: sql.statement.

## Redis::hiredis

We wrap the commands from Redis.

## WWW::Curl

We wrap WWW::Curl::Easy in the simple sense and use a more complex concept
of non-heirarchical (or floating) spans to support WWW::Curl::Multi.

We add annotations: http.uri, http.hostname, http.status.

Additionally, we "manipulate" requests going out to append X-B3-\* headers so
that downstream HTTP services can report on the spans.

# EXTENDING

All extensions should leverage the `tracer_wrap` function.

### tracer\_wrap($function, %options)

`%options` may include

- name => $scalar \[default: "$function"\]
- name => sub(\\@\_) { return $scalar; }

    A name or naming function for the span.

- newspan => 1 \[default: 0\]

    This will cause a new span to be created and pushed into the heirrchy.
    The span will have a parent of the current span and a new span id assigned.
    As this is designed for talking to other distributed components, the
    Zipkin `CLIENT_SEND` and `CLIENT_RECIEVE` annotations will be added
    automatically (unless `wants_start` or `wants_end` are disabled).

- floatingspan => 1 \[default: 0\]

    If floatingspan is enabled, new spans are not added to the heirarchy.
    They "float" and you are responsible for them.

- wants\_end => 0 \[default: 1\]
- wants\_start => 0 \[default: 1\]

    Optionally disables the `CLIENT_SEND` and `CLIENT_RECIEVE` annotations
    on new spans.

- preamble => sub($trace\_id, \\@\_) { return $span; } \[default: undef\]

    Run some code before any new span is created and optionall create and
    return that span.

- postamble => sub($trace\_id, \\@\_, \\@rv)

    Run some code when we're finished the wrapping.

- pre\_bins => \[ sub($span, \\@\_) {return @bins;} \[, ... \]\]\]
- post\_bins => \[ sub($span, \\@\_, \\@rv) {return @bins;} \[, ... \]\]\]

    A list of functions that return a list of Zipkin BinaryAnnotations.
    `pre_bins` are run before the wrapped function executes and `post_bins`
    are run after the function executes (with the return values as `@rv`).

    Annotations are a hash containing "key", "value", and optionally an
    "annotation\_type" of ("BOOL", "BYTES", "I16", "I32", "I64", "DOUBLE", or
    "STRING") and an optional "host" that is a `Zipkin::Endpoint`.  The
    host will default to a reasonable Endpoint and should not be provided
    unless you are reporting a annotation on behalf of another.

- add\_trace\_cleaner( sub )

    Adds a cleanup handler that will run when all traces finish. Do not
    register per-trace, only globally.

# CAVEATS AND BUGS

This is all black magic (as is most of Perl anyway).

This will not work with a threaded perl.

Due to the asynchronous nature of `Logger::Fq`, processes that exit
(like CLI tools and regular scripts) will notice between one and two
seconds of lag time (sleeping) on exit where we allow time for the
Logger::Fq asynchronous backlog to be sent out.  Entirely impoerfect,
but usually "good enough."  This has no noticeable effect on long-running
perl processes (most specifically mod\_perl apps).
