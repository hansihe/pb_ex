# Benchmarks

PB is a data-driven library: it interprets a compiled schema at runtime rather
than generating bespoke encode/decode code for each message. The Elixir
[`protobuf`](https://hex.pm/packages/protobuf) library takes the opposite
approach, generating a dedicated module per message with `protoc-gen-elixir`.

That design difference has a performance cost, and PB is the slower of the two.
On the scenarios below, encoding runs roughly **1.4–1.8× slower** than
`protobuf` and decoding roughly **2.5–3.2× slower**, with several times the
memory allocated per operation. PB decodes into plain maps and walks the schema
to do it; `protobuf` materializes a struct it has generated code for. If raw
throughput is the deciding factor, `protobuf` is faster. PB trades that speed
for its data-driven model — no code generation, no build step, schemas that
travel as data.

The numbers below compare PB's compile-time path (`use PB.Schema`, the direct
analogue of generated modules) against `protobuf`'s generated modules.

Wire throughput is only one axis, though. On compile time and runtime memory
the data-driven model is the clear winner — see [Compile time and runtime
footprint](#compile-time-and-runtime-footprint) below.

## Methodology

Both libraries encode and decode the same schema
([`bench/proto/pb_bench.proto`](https://github.com/hansihe/pb/blob/main/bench/proto/pb_bench.proto))
and the same payloads, across four scenarios:

- **person/full** — a nested message with repeated fields, a oneof, and a map.
- **person/sparse** — the same message with a single field set.
- **scalars** — one field of every scalar wire type.
- **packed** — long repeated numeric fields (packed encoding).

Before timing, the suite runs a correctness gate: each library decodes the
other's bytes and the results must match, so the comparison is only ever between
encoders that agree on the wire.

PB's native encode output is iodata; the "binary" rows add
`IO.iodata_to_binary/1` to match `protobuf`, which returns a binary.

## Results

Captured by [`bench/run.sh`](https://github.com/hansihe/pb/blob/main/bench/run.sh)
on Benchee. Absolute timings depend on hardware; the ratios are the stable part.

<!-- BENCHMARK RESULTS START -->
```text
  ok  person/full nested repeated map (byte-identical, 479 B)
  ok  person/sparse defaults (byte-identical, 2 B)
  ok  scalars/all scalar wire types (byte-identical, 161 B)
  ok  packed/repeated numerics (byte-identical, 2884 B)

=== ENCODE (Elixir term -> wire bytes) ===
Operating System: macOS
CPU Information: Apple M1 Max
Number of Available Cores: 10
Available memory: 32 GB
Elixir 1.19.5
Erlang 28.4.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: packed/repeated numerics, person/full nested repeated map, person/sparse defaults, scalars/all scalar wire types
Estimated total run time: 1 min 48 s
Excluding outliers: false


##### With input packed/repeated numerics #####
Name                               ips        average  deviation         median         99th %
protobuf encode (binary)       20.34 K       49.18 μs    ±12.91%       51.29 μs       65.96 μs
PB encode (iodata)             15.05 K       66.46 μs    ±33.73%       61.83 μs      115.21 μs
PB encode (binary)             13.46 K       74.29 μs    ±14.60%          70 μs      119.33 μs

Comparison: 
protobuf encode (binary)       20.34 K
PB encode (iodata)             15.05 K - 1.35x slower +17.29 μs
PB encode (binary)             13.46 K - 1.51x slower +25.11 μs

Memory usage statistics:

Name                        Memory usage
protobuf encode (binary)        92.23 KB
PB encode (iodata)             220.85 KB - 2.39x memory usage +128.63 KB
PB encode (binary)             220.91 KB - 2.40x memory usage +128.69 KB

**All measurements for memory usage were the same**

##### With input person/full nested repeated map #####
Name                               ips        average  deviation         median         99th %
protobuf encode (binary)       62.36 K       16.03 μs    ±17.23%       15.71 μs       18.88 μs
PB encode (iodata)             38.37 K       26.06 μs    ±46.44%       24.88 μs       37.91 μs
PB encode (binary)             34.24 K       29.20 μs    ±46.90%       27.96 μs       43.85 μs

Comparison: 
protobuf encode (binary)       62.36 K
PB encode (iodata)             38.37 K - 1.63x slower +10.03 μs
PB encode (binary)             34.24 K - 1.82x slower +13.17 μs

Memory usage statistics:

Name                        Memory usage
protobuf encode (binary)        24.68 KB
PB encode (iodata)              68.55 KB - 2.78x memory usage +43.87 KB
PB encode (binary)              68.58 KB - 2.78x memory usage +43.90 KB

**All measurements for memory usage were the same**

##### With input person/sparse defaults #####
Name                               ips        average  deviation         median         99th %
PB encode (iodata)              2.00 M      500.77 ns  ±1544.06%         458 ns         625 ns
PB encode (binary)              1.80 M      554.33 ns  ±1561.02%         500 ns         709 ns
protobuf encode (binary)        1.39 M      721.96 ns   ±853.52%         667 ns        1792 ns

Comparison: 
PB encode (iodata)              2.00 M
PB encode (binary)              1.80 M - 1.11x slower +53.57 ns
protobuf encode (binary)        1.39 M - 1.44x slower +221.20 ns

Memory usage statistics:

Name                        Memory usage
PB encode (iodata)                 896 B
PB encode (binary)                 920 B - 1.03x memory usage +24 B
protobuf encode (binary)           488 B - 0.54x memory usage -408 B

**All measurements for memory usage were the same**

##### With input scalars/all scalar wire types #####
Name                               ips        average  deviation         median         99th %
protobuf encode (binary)      359.18 K        2.78 μs   ±262.49%        2.67 μs        4.08 μs
PB encode (iodata)            253.14 K        3.95 μs   ±216.15%        3.83 μs        4.88 μs
PB encode (binary)            209.79 K        4.77 μs   ±530.12%        4.25 μs        8.38 μs

Comparison: 
protobuf encode (binary)      359.18 K
PB encode (iodata)            253.14 K - 1.42x slower +1.17 μs
PB encode (binary)            209.79 K - 1.71x slower +1.98 μs

Memory usage statistics:

Name                        Memory usage
protobuf encode (binary)         3.29 KB
PB encode (iodata)               6.74 KB - 2.05x memory usage +3.45 KB
PB encode (binary)               6.80 KB - 2.07x memory usage +3.52 KB

**All measurements for memory usage were the same**

=== DECODE (wire bytes -> Elixir term) ===
Operating System: macOS
CPU Information: Apple M1 Max
Number of Available Cores: 10
Available memory: 32 GB
Elixir 1.19.5
Erlang 28.4.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: packed/repeated numerics, person/full nested repeated map, person/sparse defaults, scalars/all scalar wire types
Estimated total run time: 1 min 48 s
Excluding outliers: false


##### With input packed/repeated numerics #####
Name                              ips        average  deviation         median         99th %
protobuf decode               50.96 K       19.62 μs    ±11.21%       18.88 μs       24.13 μs
PB decode (no defaults)       20.43 K       48.96 μs    ±28.42%       47.71 μs       63.29 μs
PB decode (defaults)          20.12 K       49.71 μs     ±5.51%       48.96 μs       57.25 μs

Comparison: 
protobuf decode               50.96 K
PB decode (no defaults)       20.43 K - 2.49x slower +29.34 μs
PB decode (defaults)          20.12 K - 2.53x slower +30.08 μs

Memory usage statistics:

Name                       Memory usage
protobuf decode                38.91 KB
PB decode (no defaults)       141.15 KB - 3.63x memory usage +102.23 KB
PB decode (defaults)          141.34 KB - 3.63x memory usage +102.42 KB

**All measurements for memory usage were the same**

##### With input person/full nested repeated map #####
Name                              ips        average  deviation         median         99th %
protobuf decode               66.73 K       14.99 μs    ±19.79%       14.58 μs       16.96 μs
PB decode (no defaults)       21.15 K       47.27 μs     ±6.24%       46.66 μs       56.08 μs
PB decode (defaults)          20.82 K       48.04 μs     ±7.84%       47.54 μs       55.79 μs

Comparison: 
protobuf decode               66.73 K
PB decode (no defaults)       21.15 K - 3.15x slower +32.28 μs
PB decode (defaults)          20.82 K - 3.21x slower +33.05 μs

Memory usage statistics:

Name                       Memory usage
protobuf decode                20.02 KB
PB decode (no defaults)       150.09 KB - 7.50x memory usage +130.07 KB
PB decode (defaults)          152.45 KB - 7.61x memory usage +132.43 KB

**All measurements for memory usage were the same**

##### With input person/sparse defaults #####
Name                              ips        average  deviation         median         99th %
protobuf decode                5.06 M      197.46 ns  ±3893.58%         167 ns         250 ns
PB decode (no defaults)        1.85 M      540.68 ns  ±1593.55%         500 ns         708 ns
PB decode (defaults)           1.18 M      848.40 ns   ±827.15%         792 ns        1041 ns

Comparison: 
protobuf decode                5.06 M
PB decode (no defaults)        1.85 M - 2.74x slower +343.22 ns
PB decode (defaults)           1.18 M - 4.30x slower +650.94 ns

Memory usage statistics:

Name                       Memory usage
protobuf decode                0.133 KB
PB decode (no defaults)         1.31 KB - 9.88x memory usage +1.18 KB
PB decode (defaults)            2.23 KB - 16.76x memory usage +2.09 KB

**All measurements for memory usage were the same**

##### With input scalars/all scalar wire types #####
Name                              ips        average  deviation         median         99th %
protobuf decode              505.30 K        1.98 μs    ±14.31%        1.96 μs        2.29 μs
PB decode (defaults)         172.74 K        5.79 μs   ±111.05%        5.67 μs        7.08 μs
PB decode (no defaults)      172.62 K        5.79 μs    ±77.69%        5.63 μs        7.21 μs

Comparison: 
protobuf decode              505.30 K
PB decode (defaults)         172.74 K - 2.93x slower +3.81 μs
PB decode (no defaults)      172.62 K - 2.93x slower +3.81 μs

Memory usage statistics:

Name                       Memory usage
protobuf decode                 3.28 KB
PB decode (defaults)           19.16 KB - 5.84x memory usage +15.88 KB
PB decode (no defaults)        18.71 KB - 5.70x memory usage +15.43 KB

**All measurements for memory usage were the same**
```
<!-- BENCHMARK RESULTS END -->

## Compile time and runtime footprint

The encode/decode numbers above are the axis where `protobuf` wins. There is
another axis, not captured by a microbenchmark, where the data-driven model wins
decisively: the cost of the schema itself.

`protobuf` generates one Elixir module per message. A schema with thousands of
messages becomes thousands of modules to compile, and that cost is paid on every
build — in large schemas compilation can stretch into minutes. Those modules
also stay resident: each loaded BEAM module carries runtime overhead (its code,
atoms, and metadata) for the life of the VM, so a large generated schema has a
standing memory cost independent of how much data you actually encode.

PB compiles a schema into *data*. With `use PB.Schema` the whole schema becomes
one module holding a single compiled structure; with the runtime `PB.compile/1`
path there is no generated module at all. Either way, compile time is roughly
independent of the number of messages, and there is no per-message module loaded
at runtime. For large or rapidly-changing schemas this is often the more
consequential difference in practice, even though it does not show up in the
per-operation timings above.

## Reproducing

The benchmark lives in its own project under `bench/` so the main `pb` package
stays dependency-free. To run it:

```sh
cd bench
mix run pb_vs_protobuf.exs
```

Timing knobs (seconds): `BENCH_WARMUP`, `BENCH_TIME`, `BENCH_MEMORY`.

To regenerate the proto artifacts, rerun the suite, and refresh the results
block on this page in one step:

```sh
bench/run.sh
```
