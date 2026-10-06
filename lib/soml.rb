# frozen_string_literal: true

require_relative 'soml/version'

# Read and write SOML, a config format for humans.
#
# @see https://github.com/soml-lang/soml The specification
module SOML
	# The deepest nesting either direction accepts. Every array and object is one level, including the document's own collection.
	MAX_DEPTH = 100

	INT64_MIN = -(2**63)
	INT64_MAX = (2**63) - 1

	# The duration units in their required order, with their length in nanoseconds.
	DURATION_UNITS = {
		'h' => 3_600_000_000_000,
		'm' => 60_000_000_000,
		's' => 1_000_000_000,
		'ms' => 1_000_000,
		'us' => 1000,
		'ns' => 1
	}.freeze

	# A byte that a bare key can hold, as a table of 256 booleans, for the {Parser} and the {Tree}.
	BARE_KEY_BYTE = Array.new(256) { |byte| byte.chr.match?(/[A-Za-z0-9_-]/) }.freeze

	# A number, an instant, or a duration is one maximal run of these bytes, which the {Parser} then validates as a whole. A keyword ends at the first byte that is not one, too, because the parser checked that it is followed by whitespace, a separator, a closing bracket, a comment, or the end.
	NUMBER_BYTE = Array.new(256) { |byte| byte.chr.match?(/[A-Za-z0-9_.:+-]/) }.freeze

	# A line of a block string without one of these is blank. A search for one character, because a repeat over a long line needs memory for every character.
	NOT_BLANK_CHARACTER = /[^\t ]/

	# The default of the `value` of {SOML.edit}, which tells a missing value from `nil`.
	NO_VALUE = Object.new.freeze

	# The indentation of each level, so that the {Generator} and the {Printer} make no string for each line they indent. The {Printer} indents a value after a comment one level deeper than its key, so each container can be two levels deeper than the one that holds it, and a value after a comment in the deepest container is at level 200.
	INDENTS = Array.new((MAX_DEPTH * 2) + 1) { |level| ("\t" * level).freeze }.freeze

	private_constant :MAX_DEPTH, :INT64_MIN, :INT64_MAX, :DURATION_UNITS, :NO_VALUE, :BARE_KEY_BYTE, :NUMBER_BYTE, :NOT_BLANK_CHARACTER, :INDENTS

	# Whether a key can be written without quotes, as a bare key: one or more ASCII letters, digits, `_`, or `-`, in any order, so `404` and `-x` are bare keys too. {SOML.generate} writes such a key bare and quotes every other key.
	#
	# @param key [String, Symbol] A key in UTF-8, or a symbol, which is read as its name. A key in an encoding that is not compatible with ASCII, such as UTF-16, is read as the UTF-8 string it converts to, as {SOML.generate} reads it. Any other object is not a key, so it gives false.
	# @return [Boolean]
	#
	# @example
	#   SOML.bare_key?('content-type')
	#   #=> true
	#
	#   SOML.bare_key?('a.b')
	#   #=> false
	def self.bare_key?(key)
		# Only a String or a Symbol is a key. Anything else, such as a number or nil, could never be a bare key, so the answer is false rather than a crash on its missing `encoding`.
		return false unless String === key || Symbol === key

		# The byte scan needs a String, so a Symbol is read as its name. A String, even a subclass, is left as it is, as the regex did.
		key = key.to_s unless String === key
		key = key.encode(Encoding::UTF_8) unless key.encoding.ascii_compatible?

		# A scan of the bytes, which is faster than the regex it replaces and decides the same: a byte that is not an ASCII letter, digit, `_`, or `-` means the key needs quotes. A non-ASCII character is a run of bytes none of which a bare key can hold.
		return false if key.empty?

		index = 0
		length = key.bytesize

		while index < length
			return false unless BARE_KEY_BYTE[key.getbyte(index)]

			index += 1
		end

		true
	rescue ArgumentError, EncodingError
		# Invalid bytes, or a key that does not convert to UTF-8.
		false
	end

	# Parse a document.
	#
	# @param source [String] The document. A UTF-8, binary, or US-ASCII string is read as UTF-8, and a string in another encoding is converted to UTF-8 first.
	# @param symbolize_names [Boolean] Whether object keys are symbols rather than strings.
	# @param freeze [Boolean] Whether the result is deeply frozen, which also makes it shareable between ractors.
	# @return [Hash, Array] The object or array the document contains.
	# @raise [ParseError] When the document is not valid.
	# @raise [TypeError] When `source` is not a string.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.parse(<<~SOML)
	#     name: 'api-gateway'
	#     replicas: 3
	#     timeout: 30s
	#     postgres: {host: 'db.internal'}
	#   SOML
	#   #=> {"name" => "api-gateway", "replicas" => 3, "timeout" => #<SOML::Duration 30s>, "postgres" => {"host" => "db.internal"}}
	def self.parse(source, symbolize_names: false, freeze: false)
		Parser.new(source, symbolize_names:, freeze:).parse
	end

	# Read and parse a file.
	#
	# The file is read in binary mode, so that a carriage return, which a document may not contain, is not hidden by a text-mode conversion. An error names the file, as in `Duplicate key port at config.soml:3:1`.
	#
	# @param path [String, #to_path] The file, such as a `Pathname` or a `File`.
	# @param symbolize_names [Boolean] See {SOML.parse}.
	# @param freeze [Boolean] See {SOML.parse}.
	# @return [Hash, Array] The object or array the document contains.
	# @raise [ParseError] When the document is not valid. Its message and {ParseError#path} name the file.
	# @raise [SystemCallError] When the file cannot be read, such as `Errno::ENOENT`.
	#
	# @example
	#   config = SOML.load_file('config.soml', symbolize_names: true)
	def self.load_file(path, symbolize_names: false, freeze: false)
		Parser.new(File.binread(path), symbolize_names:, freeze:, path: File.path(path)).parse
	end

	# Write a hash or an array as SOML.
	#
	# Members keep the order of their hash, nesting is written with braces and tabs, and the text ends with one line feed. Comments and block strings are never written. Everything but the order of members is canonical form, so the text is canonical form when the keys are already sorted.
	#
	# With `canonical: true`, members are sorted by key too, so the text is canonical form. Two equal values then give the same text, which can be hashed, signed, or compared.
	#
	# @param value [Hash, Array] The document.
	# @param canonical [Boolean] Whether to write canonical form, with members sorted by key.
	# @return [String] The text, in UTF-8.
	# @raise [GenerateError] For a value that cannot be written, such as NaN, an integer outside the 64-bit range, a key that is not a string or a symbol, or an object of another class.
	#
	# @example
	#   SOML.generate({name: 'api-gateway', replicas: 3, ratio: 0.5})
	#   #=> "name: 'api-gateway'\nreplicas: 3\nratio: 0.5\n"
	#
	#   SOML.generate({name: 'api-gateway', replicas: 3, ratio: 0.5}, canonical: true)
	#   #=> "name: 'api-gateway'\nratio: 0.5\nreplicas: 3\n"
	def self.generate(value, canonical: false)
		Generator.new(canonical:).generate(value)
	end

	# Format a document. Returns the document with its layout normalized, ending with one line feed.
	#
	# The layout follows the formatter in the specification: one tab per level, every member and item on its own line with no commas, and no trailing whitespace or runs of blank lines. An object or an array whose brackets are on one line stays on one line, as in `ports: [80, 443]`, with a comma and a space between its members or items. To give a one-line container one member or item per line, put a line break anywhere inside it. Comments, member order, block strings, and the spelling of every value stay as they are, so the value never changes. The one change inside a block comment is the same layout rule: trailing whitespace is removed, and runs of blank lines collapse to one.
	#
	# In detail, as the specification states:
	#
	# - A block comment that a value follows on the same line, as in `1, /* note */ 2`, stays in front of that value when each item goes on its own line.
	# - One space follows each `:`, as in canonical form.
	# - A value on the line after its `key:` moves up to that line, unless a comment comes between them. Then it stays on its own line, one level deeper than the key, and the blank lines between them are removed.
	# - A block string begins on the line after its key, and its delimiters and content have the indentation of that line. Its lines are not otherwise changed.
	# - There are no blank lines at the start of the file or directly inside brackets.
	#
	# @param source [String] The document, read as {SOML.parse} reads it.
	# @return [String] The formatted document, in UTF-8, ending with one line feed.
	# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
	# @raise [TypeError] When `source` is not a string.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.format('pool: {min: 2,   max: 16,} # Connections')
	#   #=> "pool: {min: 2, max: 16} # Connections\n"
	#
	#   SOML.format("pool: {\nmin: 2, max: 16}")
	#   #=> "pool: {\n\tmin: 2\n\tmax: 16\n}\n"
	def self.format(source)
		Printer.new(Tree.new(source)).print
	end

	# Change one value in a document, and keep everything else as it is written: comments, member order, layout, and the spelling of every other value. For tools that update a config file, such as a dependency bumper or a `set` command.
	#
	# The value at `path` is replaced, or added when it does not exist yet, and `delete: true` removes it. Only the changed part of the text is rewritten, and an edit to a formatted document leaves it formatted.
	#
	# - A new value is written as {SOML.generate} writes it, in canonical form except that its members keep their order, at the indentation of its line. So `0xFF` that is replaced by `255` is written `255`. In a container that is on one line, it is written on one line too, so `[1, 2]` with a new item `{a: 3}` becomes `[1, 2, {a: 3}]`.
	# - A new member goes after the last member of its object. Missing objects on the way are created.
	# - A new item can be added at the end of an array, with the index that is its length.
	# - A new member or item goes on its own line without a comma, after the comments that the one before it owns (see below), and the commas of the other members and items stay as they are. When something follows the member or item before it on the same line, such as the closing bracket of the one-line container `{a: 1}`, it goes on that line after a comma, as in `{a: 1, b: 2}`. In an empty `[]` or `{}`, it goes on a line of its own, unless that container is inside a container on one line, so `a: [1, []]` becomes `a: [1, [2]]`.
	# - A removed member or item takes the comments it owns, which in a formatted document are the ones that {SOML.format} keeps with it: the comments after it on its line, also after its comma when nothing else follows there, and the block comments before it on its line, after the comma or bracket before it. So removing `2` from `[1, /* note */ 2]` gives `[1]`. A comment on a line of its own belongs to no member or item, so it stays. A removed member or item also removes its lines when nothing else is on them. A line that a block comment after it continues onto counts as one of its lines. Removing every item of a container closes it up to `[]` or `{}`, unless a comment is left inside.
	# - A removed member or item takes its comma with it. When the removed items are the last ones and have no comma after them, they take the comma directly before them instead, when only spaces, tabs, and the comments they own are between, so `[1, 2]` becomes `[1]`.
	# - Removing the only member of a document without braces leaves `{}`.
	#
	# Comments inside a value that is replaced or removed are removed with it. In a layout that {SOML.format} never writes, such as an item after a closing block string delimiter on its line, a new item can be indented differently from its neighbors, but the document is always valid and has the right value. Removing a value that does not exist changes nothing and is not an error: a missing member, a missing object or array on the way, or an index at or past the end of its array. So removing the same path twice is safe. The result has the same bytes as `source` exactly when nothing was removed, so `SOML.edit(source, path, delete: true).b == source.b` tells whether something was removed. The `.b` compares the bytes, because a source read in binary mode is not `==` to the UTF-8 result when it has a character that is not ASCII. This holds for a source in UTF-8, binary, or US-ASCII, because one in another encoding is converted to UTF-8.
	#
	# The result is parsed before it is returned, so a bug in `edit` raises a `RuntimeError` rather than returning a broken document.
	#
	# @overload edit(source, path, value)
	#   @param source [String] The document, read as {SOML.parse} reads it.
	#   @param path [Array<String, Symbol, Integer>] The keys and array indexes that lead to the value, such as `['servers', 0, 'port']`.
	#   @param value [Object] The new value, of the types that {SOML.generate} accepts. Write a `Hash` with braces, because without them Ruby passes its members as keyword arguments.
	#   @return [String] The changed document, in UTF-8.
	# @overload edit(source, path, delete: true)
	#   @param source [String] The document, read as {SOML.parse} reads it.
	#   @param path [Array<String, Symbol, Integer>] The keys and array indexes that lead to the value.
	#   @param delete [true] Remove the value.
	#   @return [String] The changed document, in UTF-8.
	# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
	# @raise [ArgumentError] When both a value and `delete: true` are given, or neither.
	# @raise [TypeError] When `source` is not a string, when `path` is not a non-empty array of keys and array indexes, when it leads through a value that is not an object or an array, or when it has a key where an array is or an index where an object is.
	# @raise [IndexError] When a value is set at an index past the end of its array, or at an index under a value that does not exist.
	# @raise [GenerateError] For a value or a key that {SOML.generate} cannot write, and when the change would nest the document more than 100 levels deep.
	# @raise [EncodingError] When `source` is in an encoding other than UTF-8, binary, or US-ASCII, and does not convert to UTF-8.
	#
	# @example
	#   SOML.edit("name: 'api' # The service\nport: 8080\n", ['port'], 9090)
	#   #=> "name: 'api' # The service\nport: 9090\n"
	#
	#   SOML.edit("postgres: {\n\thost: 'db'\n}\n", ['postgres', 'port'], 5432)
	#   #=> "postgres: {\n\thost: 'db'\n\tport: 5432\n}\n"
	#
	#   SOML.edit("a: 1\nb: 2\n", ['a'], delete: true)
	#   #=> "b: 2\n"
	def self.edit(source, path, value = NO_VALUE, delete: false)
		if delete
			raise ArgumentError, 'Pass either a value or delete: true, not both' unless NO_VALUE.equal?(value)
		elsif NO_VALUE.equal?(value)
			raise ArgumentError, 'Pass the new value, or delete: true to remove the value'
		end

		Editor.new(source, path, value, delete:).edit
	end
end

require_relative 'soml/error'
require_relative 'soml/duration'
require_relative 'soml/parser'
require_relative 'soml/generator'
require_relative 'soml/tree'
require_relative 'soml/format'
require_relative 'soml/edit'
