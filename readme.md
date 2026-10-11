# soml-lang

> Read and write [SOML](https://soml.sh), a config format for humans, in Ruby

> [!NOTE]
> The format is a draft.

## Highlights

- Strict: every rule in the specification is enforced, and every error says what is wrong and where, with the same message as the JavaScript reference implementation
- Exact: an int is an `Integer`, a float is a `Float`, an instant is a `Time` exact to the nanosecond, and a duration is an exact count of nanoseconds
- Canonical: `SOML.generate(value, canonical: true)` writes the one canonical form, so equal values give equal text, and without it the member order of a hash is kept
- Familiar: the API of `json`, with `parse`, `load_file`, `generate`, `symbolize_names:`, and `freeze:`
- Lossless: `SOML.format` normalizes the layout and `SOML.edit` changes one value, and both keep the comments, member order, and spelling of everything else
- Safe: linear time and memory on every input shape, no stack overflow on deep input, and every error in a document is a `SOML::ParseError`
- Ractor-safe, with no dependencies

## Install

```sh
gem install soml-lang
```

Or in a `Gemfile`:

```ruby
gem 'soml-lang'
```

[On RubyGems](https://rubygems.org/gems/soml-lang). Requires Ruby 4.0 or later.

## Usage

```ruby
require 'soml'

config = SOML.parse(<<~SOML)
	# The edge service.
	name: 'api-gateway'
	replicas: 3
	timeout: 30.0
	grace: 1m30s
	deployed-at: 2026-09-19T14:00:00Z
	postgres: {host: 'db.internal'}
SOML
#=> {
# 	"name" => "api-gateway",
# 	"replicas" => 3,
# 	"timeout" => 30.0,
# 	"grace" => #<SOML::Duration 1m30s>,
# 	"deployed-at" => 2026-09-19 14:00:00 UTC,
# 	"postgres" => {"host" => "db.internal"}
# }

puts SOML.generate(config)
# name: 'api-gateway'
# replicas: 3
# timeout: 30.0
# grace: 1m30s
# deployed-at: 2026-09-19T14:00:00Z
# postgres: {
# 	host: 'db.internal'
# }
```

Read a file:

```ruby
config = SOML.load_file('config.soml', symbolize_names: true)
config[:postgres][:host]
#=> "db.internal"
```

Write a file in binary mode, so that Windows does not turn each line feed into a CRLF, which SOML does not allow:

```ruby
File.binwrite('config.soml', SOML.generate(config))
```

## Types

| SOML | Ruby | `generate` also accepts |
|---|---|---|
| string | `String`, in UTF-8 | `Symbol`, and a `String` in any encoding that converts to UTF-8 |
| int | `Integer` | |
| float | `Float` | |
| bool | `true`, `false` | |
| null | `nil` | |
| instant | `Time`, in UTC | a `Time` with any offset |
| duration | [`SOML::Duration`](#somlduration) | |
| array | `Array` | |
| object | `Hash` with `String` keys, in document order, or `Symbol` keys with `symbolize_names: true` | `Symbol` keys |

An int is an `Integer` and a float is a `Float` in both directions, so `3` and `3.0` keep their types:

```ruby
SOML.parse("a: 3\nb: 3.0")
#=> {"a" => 3, "b" => 3.0}

SOML.generate({a: 3, b: 3.0})
#=> "a: 3\nb: 3.0\n"
```

> [!IMPORTANT]
> Ruby compares `3 == 3.0` as true, so `SOML.parse('a: 3') == SOML.parse('a: 3.0')` is true even though the types differ. `eql?` compares the types too, so `SOML.parse('a: 3').eql?(SOML.parse('a: 3.0'))` is false.

With this mapping, two things always hold:

- `SOML.parse(SOML.generate(value))` equals `value`, for a value made of the types `parse` returns. (A `Time` comes back in UTC, a `Symbol` as a `String`, and `-0.0` as `0.0`.)
- `SOML.generate(SOML.parse(text), canonical: true)` is the canonical form of `text`, and `SOML.generate(SOML.parse(canonical), canonical: true) == canonical`.

An instant is a `Time` in UTC, because the offset is how the instant was written, not part of its value:

```ruby
SOML.parse('a: 2026-09-19T14:00:00.123456789+02:00')['a']
#=> 2026-09-19 12:00:00.123456789 UTC
```

## API

### SOML.parse(source, symbolize_names: false, freeze: false)

Parse a document. Returns a `Hash` or an `Array`, because a document is always a collection.

`source` is a `String`, or an object with `to_str`. A UTF-8, binary, or US-ASCII string is read as UTF-8, and invalid UTF-8 is a `SOML::ParseError` with its position. A string in another encoding, such as UTF-16, is converted to UTF-8 first, as `JSON.parse` does, and an `EncodingError` is raised when it does not convert.

Raises `SOML::ParseError` when the document is not valid, and `TypeError` when `source` is not a string.

#### symbolize_names

Type: `Boolean`\
Default: `false`

Whether object keys are symbols rather than strings.

```ruby
SOML.parse('postgres: {host: "db"}', symbolize_names: true)
#=> {postgres: {host: "db"}}
```

#### freeze

Type: `Boolean`\
Default: `false`

Whether the result is deeply frozen, which also makes it shareable between ractors.

```ruby
config = SOML.parse("hosts: ['a', 'b']", freeze: true)
config['hosts'].frozen?
#=> true
Ractor.shareable?(config)
#=> true
```

### SOML.load_file(path, symbolize_names: false, freeze: false)

Read and parse a file. `path` is a `String`, or an object with `to_path`, such as a `Pathname`. The options are those of `SOML.parse`.

The file is read in binary mode, so that a text-mode conversion cannot hide a carriage return, which a document may not contain.

Raises `SOML::ParseError` when the document is not valid, and a `SystemCallError`, such as `Errno::ENOENT`, when the file cannot be read. The error names the file, so that an editor or a terminal can open it at the position:

```ruby
SOML.load_file('config.soml')
# Raises SOML::ParseError: Duplicate key port at config.soml:3:1
```

### SOML.generate(value, canonical: false)

Write a `Hash` or an `Array` as SOML. Members keep the order of their hash, nesting is written with braces and tabs, and the text ends with one line feed. Comments and block strings are never written.

Everything but the order of members follows canonical form, so the text is canonical form when the keys are already sorted. Use `canonical: true` when the text is hashed, signed, or compared.

```ruby
SOML.generate({name: 'api', ports: [80, 443], description: 'The edge service'})
#=> "name: 'api'\nports: [\n\t80\n\t443\n]\ndescription: 'The edge service'\n"
```

Raises `SOML::GenerateError` for a value that cannot be written:

- a top-level value that is not a `Hash` or an `Array`, because a document is a collection
- `Float::NAN`, which SOML does not have (use `nil` for a missing value)
- an `Integer` outside the 64-bit range
- a `Time` outside the years 0001 to 9999 in UTC, or with a fraction of a second finer than a nanosecond
- a string or key with a carriage return, or one that is not valid UTF-8 or does not convert to UTF-8 (a binary or US-ASCII string is read as UTF-8, as `SOML.parse` reads one)
- a key that is not a `String` or a `Symbol`, because a key is never converted, and two keys that are the same string, such as `:a` and `'a'`
- a circular reference, and nesting deeper than 100 levels
- an object of any other class, such as a `Date` (write it as a string), a `Rational`, or an `ActiveSupport::Duration` (use a `SOML::Duration`). A `Struct`, `Data`, `Set`, or `Pathname` is not converted, because it would read back as another class, and the message names the conversion to use, such as `to_h`

The message says where the value is:

```ruby
SOML.generate({servers: [{ratio: Float::NAN}]})
# Raises SOML::GenerateError: NaN is not representable. Use nil for a missing value (at servers[0].ratio)
```

#### canonical

Type: `Boolean`\
Default: `false`

Whether to write canonical form, with the members of each object sorted by key. Canonical form is unique for a value: two equal values give the same text, so it can be hashed, signed, or compared.

```ruby
SOML.generate({name: 'api', ports: [80, 443], description: 'The edge service'}, canonical: true)
#=> "description: 'The edge service'\nname: 'api'\nports: [\n\t80\n\t443\n]\n"
```

### SOML.format(source)

Format a document. Returns the document with its layout normalized, ending with one line feed.

The layout follows the [formatter](https://github.com/soml-lang/soml/blob/main/spec.md#formatting) in the specification: one tab per level, every member and item on its own line with no commas, and no trailing whitespace or runs of blank lines. A container whose brackets are on one line stays on one line, as in `ports: [80, 443]`. Put a line break anywhere inside it to give it one member or item per line. Comments, member order, block strings, and the spelling of every value stay as they are, so the value never changes. Inside a block comment, only trailing whitespace and runs of blank lines change.

`source` is read as `SOML.parse` reads it, with the same errors.

```ruby
SOML.format('pool: {min: 2,   max: 16,} # Connections')
#=> "pool: {min: 2, max: 16} # Connections\n"

SOML.format("pool: {\nmin: 2, max: 16}")
#=> "pool: {\n\tmin: 2\n\tmax: 16\n}\n"
```

In detail, as the specification states:

- A block comment that a value follows on the same line, as in `1, /* note */ 2`, stays in front of that value when each item goes on its own line.
- One space follows each `:`, as in canonical form.
- A value on the line after its `key:` moves up to that line, unless a comment comes between them. Then it stays on its own line, one level deeper than the key, and the blank lines between them are removed.
- A block string begins on the line after its key, and its delimiters and content have the indentation of that line. Its lines are not otherwise changed.
- There are no blank lines at the start of the file or directly inside brackets.

### SOML.edit(source, path, value)

Change one value in a document, and keep everything else as it is written: comments, member order, layout, and the spelling of every other value. For tools that update a config file, such as a dependency bumper or a `set` command.

The value at `path` is replaced, or added when it does not exist yet. `SOML.edit(source, path, delete: true)` removes it instead. Only the changed part of the text is rewritten, and an edit to a formatted document leaves it formatted.

```ruby
SOML.edit("name: 'api' # The service\nport: 8080\n", ['port'], 9090)
#=> "name: 'api' # The service\nport: 9090\n"

SOML.edit("postgres: {\n\thost: 'db'\n}\n", ['postgres', 'port'], 5432)
#=> "postgres: {\n\thost: 'db'\n\tport: 5432\n}\n"

SOML.edit("a: 1\nb: 2\n", ['a'], delete: true)
#=> "b: 2\n"
```

Read and write the file in binary mode, as for `SOML.generate`:

```ruby
File.binwrite('config.soml', SOML.edit(File.binread('config.soml'), ['postgres', 'port'], 5433))
```

- A new value is written as `SOML.generate` writes it, in canonical form except that its members keep their order, at the indentation of its line. So `0xFF` that is replaced by `255` is written `255`. In a container that is on one line, it is written on one line too, so `[1, 2]` with a new item `{a: 3}` becomes `[1, 2, {a: 3}]`.
- A new member goes after the last member of its object. Missing objects on the way are created.
- A new item can be added at the end of an array, with the index that is its length.
- A new member or item goes on its own line without a comma, after the comments that the one before it owns (see below), and the commas of the other members and items stay as they are. When something follows the member or item before it on the same line, such as the closing bracket of the one-line container `{a: 1}`, it goes on that line after a comma, as in `{a: 1, b: 2}`. In an empty `[]` or `{}`, it goes on a line of its own, unless that container is inside a container on one line, so `a: [1, []]` becomes `a: [1, [2]]`.
- A removed member or item takes the comments it owns, which in a formatted document are the ones that `SOML.format` keeps with it: the comments after it on its line, also after its comma when nothing else follows there, and the block comments before it on its line, after the comma or bracket before it. So removing `2` from `[1, /* note */ 2]` gives `[1]`. A comment on a line of its own belongs to no member or item, so it stays. A removed member or item also removes its lines when nothing else is on them. A line that a block comment after it continues onto counts as one of its lines. Removing every item of a container closes it up to `[]` or `{}`, unless a comment is left inside.
- A removed member or item takes its comma with it. When the removed items are the last ones and have no comma after them, they take the comma directly before them instead, when only spaces, tabs, and the comments they own are between, so `[1, 2]` becomes `[1]`.
- Removing the only member of a document without braces leaves `{}`.

Comments inside a value that is replaced or removed are removed with it. In a layout that `SOML.format` never writes, such as an item after a closing block string delimiter on its line, a new item can be indented differently from its neighbors, but the document is always valid and has the right value.

Removing a value that does not exist (a missing member, a missing object or array on the way, or an index at or past the end of its array) changes nothing, so removing the same path twice is safe. The result has the same bytes as `source` exactly when nothing was removed, so `SOML.edit(source, path, delete: true).b == source.b` tells whether something was. The `.b` is needed because a source read in binary mode is not `==` to the UTF-8 result when it has a character that is not ASCII.

The result is parsed before it is returned, so a bug in `SOML.edit` raises a `RuntimeError` rather than returning a broken document.

Raises:

- `SOML::ParseError` when `source` is not a valid document, the same as `SOML.parse`
- `TypeError` when `source` is not a string, when `path` is not a non-empty array of keys and array indexes, when it leads through a value that is not an object or an array, or when it has a key where an array is or an index where an object is
- `IndexError` when a value is set at an index past the end of its array, or at an index under a value that does not exist
- `SOML::GenerateError` for a value or a key that `SOML.generate` cannot write, and when the change would nest the document more than 100 levels deep. Its path is the place in the document.
- `ArgumentError` when both a value and `delete: true` are given, or neither
- `EncodingError` when `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8, as for `SOML.parse`

```ruby
SOML.edit('ports: [80]', ['ports', 5], 443)
# Raises IndexError: Cannot edit ports[5], because the array at ports has 1 item. Add an item at index 1
```

#### path

Type: `Array<String | Symbol | Integer>`

The keys and array indexes that lead to the value, such as `['servers', 0, 'port']`.

#### value

The new value, of the types that `SOML.generate` accepts. `nil` writes `null`. Write a `Hash` with braces, as in `SOML.edit(source, ['pool'], {min: 2})`, because without them Ruby passes its members as keyword arguments.

#### delete

Type: `Boolean`\
Default: `false`

Remove the value at `path`, instead of setting it.

### SOML.bare_key?(key)

Whether a key can be written without quotes, as a bare key: one or more ASCII letters, digits, `_`, or `-`, in any order, so `404` and `-x` are bare keys too. `SOML.generate` writes such a key bare and quotes every other key.

```ruby
SOML.bare_key?('content-type')
#=> true

SOML.bare_key?('a.b')
#=> false
```

### SOML::Duration

A length of time, exact to the nanosecond, which is what a SOML duration such as `1h30m` holds. Ruby has no duration type of its own, and `ActiveSupport::Duration` has days and months, which are not a fixed length.

It is immutable, comparable, and usable as a hash key.

```ruby
timeout = SOML.parse('timeout: 1m30s')['timeout']
#=> #<SOML::Duration 1m30s>

timeout.nanoseconds
#=> 90000000000

sleep(timeout.to_f)
```

#### SOML::Duration.new(nanoseconds:)

Make a duration from a count of nanoseconds, which must be an `Integer` in the 64-bit range, about 292 years either way.

```ruby
SOML::Duration.new(nanoseconds: 1_500_000_000)
#=> #<SOML::Duration 1.5s>
```

#### SOML::Duration.parse(text)

Read a duration written as in a document. Raises `SOML::ParseError` when it is not one.

```ruby
SOML::Duration.parse('1.5h')
#=> #<SOML::Duration 1h30m>
```

#### SOML::Duration.from_seconds(seconds)

Make a duration from a number of seconds, the inverse of `#to_r`. The seconds are rounded to the nearest nanosecond, because a `Float` such as `0.1` is not exact. Raises `TypeError` when `seconds` is not a number, and `RangeError` when it is not finite or is outside the 64-bit range.

```ruby
SOML::Duration.from_seconds(90)
#=> #<SOML::Duration 1m30s>

SOML::Duration.from_seconds(0.1)
#=> #<SOML::Duration 0.1s>
```

#### #nanoseconds

The length in nanoseconds, an `Integer`.

#### #+(other) and #-(other)

The sum or the difference of two durations. A number has no unit, so `duration + 5` is a `TypeError`. Raises `RangeError` when the result is outside the 64-bit range.

```ruby
SOML::Duration.parse('1h') + SOML::Duration.parse('30m')
#=> #<SOML::Duration 1h30m>
```

#### #-@ and #abs

The opposite duration, and the duration without its sign.

#### #zero?, #positive?, and #negative?

Whether the length is zero, more than zero, or less than zero.

#### #to_r

The length in seconds, exactly, as a `Rational`.

#### #to_f

The length in seconds as a `Float`, for `sleep` and `Timeout.timeout`.

#### #to_s

The canonical spelling, such as `1h30m`, `1.5s`, `-0.25s`, or `0s`. So `90m` is written `1h30m`, and `-250ms` is written `-0.25s`.

### SOML::ParseError

Raised when the input is not a valid document. Subclass of `SOML::Error`, which is a `StandardError`.

The `message` is the reason and the position, on one line, so that it reads well in a log. The `detailed_message`, which Ruby shows for an uncaught error, also has a code frame:

```ruby
SOML.parse("name: 'api'\nreplicas: three")
# …: Unexpected “three”. A string value must be quoted, as in 'three' at line 2, column 11 (SOML::ParseError)
#
#   1 | name: 'api'
# > 2 | replicas: three
#     |           ^
```

#### reason

What is wrong, without the position.

#### line

The 1-based line.

#### column

The 1-based column, counted in characters.

#### offset

The 0-based character index in the source read as UTF-8, so for a UTF-8 source, `source[error.offset]` is the character at the error.

#### path

The file, when the document was read by `SOML.load_file`, and otherwise `nil`.

#### code_frame

Up to three lines ending at the error, with a caret under the position. A long line is clipped around the position, and characters that a terminal would act on are replaced.

### SOML::GenerateError

Raised by `SOML.generate` for a value that cannot be written. Subclass of `SOML::Error`.

#### reason

What is wrong, without the location.

#### path

The keys and indexes that lead to the value, such as `["servers", 0, "ratio"]`, or an empty array for the top-level value.

## Recipes

### Hash a config

Equal values give equal canonical text, so hash it to compare, cache, or sign a config. Comments, the order of members, and the spelling of values do not change the hash:

```ruby
require 'digest'

Digest::SHA256.hexdigest(SOML.generate(SOML.parse("b: 1\na: 0x10 # Note."), canonical: true))
#=> the same as for SOML.parse("a: 16\nb: 1")
```

### Compare two configs

Canonical form has one sorted member on each line, so a line diff shows every change, including a change of type, which `==` misses, because `3 == 3.0` in Ruby:

```ruby
before = SOML.generate(SOML.parse("a: 3\nb: 1"), canonical: true)
after = SOML.generate(SOML.parse("a: 3.0\nb: 1"), canonical: true)
before.lines - after.lines
#=> ["a: 3\n"]
```

### Check the shape of a config

Pattern matching checks the type of each member that a program reads, and binds it to a variable, with no schema library. A config that does not match raises an error that names the member:

```ruby
config = SOML.load_file('config.soml', symbolize_names: true)
config => {name: String => name, port: Integer => port, timeout: SOML::Duration => timeout}
```

For `port: '8080'`, this raises `NoMatchingPatternError` with `Integer === "8080" does not return true`, and without a `port`, it raises `NoMatchingPatternKeyError` with `key not found: :port`.

### Read a config in Rails

`config_for` reads YAML only, so read the file in an initializer. With one top-level object for each environment, this works as `config_for` does:

```
# config/payments.soml
production: {
	timeout: 30s
	endpoint: 'https://payments.example.com'
}
development: {
	timeout: 5m
	endpoint: 'http://localhost:4000'
}
```

```ruby
# config/initializers/payments.rb
Rails.application.config.x.payments = SOML.load_file(Rails.root.join('config/payments.soml'), symbolize_names: true, freeze: true).fetch(Rails.env.to_sym)
```

An instant is a `Time` in UTC, and `in_time_zone` gives it in the zone of the app. A duration is a `SOML::Duration`, and `to_r.seconds` gives an `ActiveSupport::Duration` of the same exact length:

```ruby
Rails.configuration.x.payments[:timeout].to_r.seconds == 30.seconds
#=> true
```

To write an `ActiveSupport::Duration`, convert it with `SOML::Duration.from_seconds`:

```ruby
SOML.generate({timeout: SOML::Duration.from_seconds(5.minutes.to_r)})
#=> "timeout: 5m\n"
```

## Benchmark

The time to read and write each of the shared [benchmark fixtures](https://github.com/soml-lang/soml/blob/main/benchmark/readme.md), which hold the same data in SOML, JSON, and TOML, in CPU time on an Apple M-series machine with Ruby 4.0 and YJIT, which this gem is written for. The machine was busy, so the numbers are rough. Lower is better.

| | this gem | `json` | `oj` | `toml-rb` |
|---|---|---|---|---|
| Read `service` (3 KB) | 78 µs | 10 µs | 11 µs | 174 µs |
| Read `platform` (35 KB) | 0.61 ms | 0.10 ms | 0.07 ms | 1.2 ms |
| Read `earthquakes` (733 KB) | 14 ms | 2.2 ms | 2.8 ms | 51 ms |
| Write `service` | 51 µs | 8 µs | 8 µs | 105 µs |
| Write `platform` | 0.34 ms | 0.06 ms | 0.03 ms | 0.65 ms |
| Write `earthquakes` | 15 ms | 2.1 ms | 3.2 ms | 26 ms |

`json` and `oj` are C extensions, and `toml-rb` is pure Ruby, like this gem. The script also compares `tomlib`, `perfect_toml`, and `tomlrb`, and times `SOML.format` and `SOML.edit` on each fixture:

```sh
bundle config set --local with benchmark
bundle install
bundle exec ruby --yjit bench/benchmark.rb
```

## Limits

- **Nesting is limited to 100 levels**, as the specification requires, in reading and in writing. Every array and object is one level, including the document's own collection.
- **The gem name.** The gem is [`soml-lang`](https://rubygems.org/gems/soml-lang), because the name `soml` on RubyGems belongs to an unrelated format, which also defines `module SOML`, so the two gems cannot be loaded in one process.
- **The syntax tree is not public yet.** `SOML.format` and `SOML.edit` use one, and the [JavaScript](https://github.com/soml-lang/soml-javascript), [Python](https://github.com/soml-lang/soml-python), and [Rust](https://github.com/soml-lang/soml-rust) implementations have a public one, for tools such as linters.

## Development

```sh
bundle install
bundle exec rake
```

`SOML_EXAMPLES=10000 bundle exec rake` runs the property tests with more examples, and `SOML_SEED=1234` repeats a run.

The fixtures in [`bench/fixtures`](bench/fixtures) are a copy of the shared ones in the [`soml`](https://github.com/soml-lang/soml/tree/main/benchmark) spec repository. To update them, check out `soml` next to this repository and run `rsync --archive --delete ../soml/benchmark/ bench/fixtures/`.

The conformance suite in [`test/conformance`](test/conformance) is a copy of the one in the [`soml`](https://github.com/soml-lang/soml/tree/main/conformance) spec repository. To update it, check out `soml` next to this repository and run `../soml/sync-conformance.sh test/conformance`.
