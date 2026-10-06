# frozen_string_literal: true

module SOML
	# The syntax tree of a valid document, for {SOML.format} and {SOML.edit}.
	#
	# It is a port of the JS reference's `tree.ts`, with only what the formatter and the editor read. Every offset is a byte offset into the UTF-8 source, and `finish` is the offset after the node. A node has no line and column, a scalar has no value, and there is no list of tokens. The document is checked by {Parser} first, so the builder can assume valid input, and the comments are collected in source order.
	#
	# @api private
	class Tree
		# The nodes are structs rather than `Data`, whose `new` builds a hash of keywords for every node, which made building a tree several times as slow as parsing the document. Nothing changes a node once it is made.

		# A `# ...` comment (`:line`) or a `/* ... */` comment (`:block`).
		Comment = Struct.new(:type, :start, :finish)

		# An object, written with braces or, only at the top level, without them.
		ObjectNode = Struct.new(:members, :braced, :start, :finish) do
			def type = :object
		end

		ArrayNode = Struct.new(:elements, :start, :finish) do
			def type = :array
		end

		# A `key: value` member.
		MemberNode = Struct.new(:key, :value, :start, :finish) do
			def type = :member
		end

		# A key, with its decoded `value`.
		KeyNode = Struct.new(:value, :start, :finish)

		# A value that is not a collection. `block` is whether it is a block string.
		ScalarNode = Struct.new(:block, :start, :finish) do
			def type = :scalar
		end

		# The characters that end the search for the closing quote of a `"..."` string.
		ESCAPED_STRING_SPECIAL = /["\\]/

		private_constant(*constants(false))

		# @return [String] The source, in UTF-8.
		attr_reader :source

		# @return [ObjectNode, ArrayNode] The document's collection.
		attr_reader :body

		# @return [Array<Comment>] Every comment, in source order.
		attr_reader :comments

		# @param source [String] The document, decoded as {SOML.parse} decodes it.
		# @raise [ParseError] When the document is not valid, the same as {SOML.parse}.
		def initialize(source)
			# Validates the whole document, so the builder below can assume valid input.
			parser = Parser.new(source)
			parser.parse
			@source = parser.source
			@length = @source.bytesize
			@index = 0
			@comments = []

			skip_trivia

			@body = case @source.getbyte(@index)
			when 0x7B # {
				parse_object
			when 0x5B # [
				parse_array
			else
				parse_bare_object
			end

			skip_trivia
		end

		private

		def skip_trivia
			source = @source
			index = @index

			while (byte = source.getbyte(index))
				case byte
				when 0x20, 0x09, 0x0A
					index += 1
				when 0x23 # #
					finish = source.byteindex("\n", index) || @length
					@comments << Comment.new(:line, index, finish)
					index = finish
				when 0x2F # /
					# The parser checked that every block comment ends, so the search finds its `*/`.
					finish = source.byteindex('*/', index + 2) + 2
					@comments << Comment.new(:block, index, finish)
					index = finish
				else
					break
				end
			end

			@index = index
		end

		def parse_bare_object
			members = []

			loop do
				members << parse_member
				skip_trivia
				break if @index >= @length
			end

			ObjectNode.new(members, false, members.first.start, members.last.finish)
		end

		def parse_object
			start = @index
			members = parse_items(0x7D) { parse_member }
			ObjectNode.new(members, true, start, @index)
		end

		def parse_array
			start = @index
			elements = parse_items(0x5D) { parse_value }
			ArrayNode.new(elements, start, @index)
		end

		# The items between an opening bracket and its `closing` bracket, which is consumed too. The parser has already checked the separators, including that a comma is on the line of the item before it.
		def parse_items(closing)
			items = []
			@index += 1
			skip_trivia

			until @source.getbyte(@index) == closing
				items << yield
				skip_trivia
				next unless @source.getbyte(@index) == 0x2C # ,

				@index += 1
				skip_trivia
			end

			@index += 1
			items
		end

		def parse_member
			key = parse_key
			@index += 1 # :
			skip_trivia
			value = parse_value
			MemberNode.new(key, value, key.start, value.finish)
		end

		def parse_key
			source = @source
			start = @index
			byte = source.getbyte(start)

			if byte == 0x27 || byte == 0x22 # ' "
				finish = string_end(start)
				@index = finish
				text = source.byteslice(start + 1, finish - start - 2)

				# A `"..."` key with an escape is decoded by the parser itself, so that the tree and `SOML.parse` cannot disagree.
				return KeyNode.new(byte == 0x22 && text.include?('\\') ? read_scalar(start, finish) : text, start, finish)
			end

			finish = start
			finish += 1 while (byte = source.getbyte(finish)) && BARE_KEY_BYTE[byte]
			@index = finish
			KeyNode.new(source.byteslice(start, finish - start), start, finish)
		end

		def parse_value
			source = @source
			start = @index

			case (byte = source.getbyte(start))
			when 0x7B # {
				parse_object
			when 0x5B # [
				parse_array
			when 0x27, 0x22 # ' "
				return parse_block_string(byte) if source.getbyte(start + 1) == byte && source.getbyte(start + 2) == byte

				@index = string_end(start)
				ScalarNode.new(false, start, @index)
			else
				finish = start + 1
				finish += 1 while (byte = source.getbyte(finish)) && NUMBER_BYTE[byte]
				@index = finish
				ScalarNode.new(false, start, finish)
			end
		end

		# The offset after the closing quote of the one-line string at `start`. `'...'` ends at the next `'`. `"..."` ends at the next `"` that is not escaped, and `\` always starts a two-character escape or a `\u{…}`, which holds no quote.
		def string_end(start)
			source = @source
			return source.byteindex("'", start + 1) + 1 if source.getbyte(start) == 0x27

			index = start + 1

			loop do
				index = source.byteindex(ESCAPED_STRING_SPECIAL, index)
				return index + 1 if source.getbyte(index) == 0x22

				index += 2
			end
		end

		# The block ends at the first line whose first non-whitespace content is a run of exactly as many quotes as the opening delimiter.
		def parse_block_string(quote)
			source = @source
			start = @index
			delimiter_length = 0
			delimiter_length += 1 while source.getbyte(start + delimiter_length) == quote
			line_start = source.byteindex("\n", start) + 1

			loop do
				delimiter_start = line_start
				delimiter_start += 1 while (byte = source.getbyte(delimiter_start)) == 0x20 || byte == 0x09
				run_length = 0
				run_length += 1 while source.getbyte(delimiter_start + run_length) == quote

				if run_length == delimiter_length
					@index = delimiter_start + delimiter_length
					return ScalarNode.new(true, start, @index)
				end

				line_start = source.byteindex("\n", line_start) + 1
			end
		end

		# The value of the scalar from `start` to `finish`, read by the parser. A scalar's validity does not depend on its context, so it parses on its own inside an array.
		def read_scalar(start, finish)
			Parser.new("[#{@source.byteslice(start, finish - start)}]").parse.first
		end
	end
end
