const std = @import("std");

const CommandClass = enum { exploration, filter, unknown };
const Separator = enum { start, pipe, statement };

const Word = struct {
    source: []const u8,

    fn eql(self: Word, expected: []const u8) bool {
        var iterator: ByteIterator = .{ .source = self.source };
        for (expected) |byte| if ((iterator.next() orelse return false) != byte) return false;
        return iterator.next() == null;
    }

    fn startsWith(self: Word, expected: []const u8) bool {
        var iterator: ByteIterator = .{ .source = self.source };
        for (expected) |byte| if ((iterator.next() orelse return false) != byte) return false;
        return true;
    }

    fn contains(self: Word, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var window: [16]u8 = undefined;
        if (needle.len > window.len) return false;
        var length: usize = 0;
        var iterator: ByteIterator = .{ .source = self.source };
        while (iterator.next()) |byte| {
            if (length < needle.len) {
                window[length] = byte;
                length += 1;
            } else {
                @memmove(window[0 .. needle.len - 1], window[1..needle.len]);
                window[needle.len - 1] = byte;
            }
            if (length == needle.len and std.mem.eql(u8, window[0..needle.len], needle)) return true;
        }
        return false;
    }

    fn byteAt(self: Word, wanted: usize) ?u8 {
        var iterator: ByteIterator = .{ .source = self.source };
        var index: usize = 0;
        while (iterator.next()) |byte| : (index += 1) if (index == wanted) return byte;
        return null;
    }
};

const ByteIterator = struct {
    source: []const u8,
    offset: usize = 0,
    quote: u8 = 0,

    fn next(self: *ByteIterator) ?u8 {
        while (self.offset < self.source.len) {
            const byte = self.source[self.offset];
            if (self.quote != 0) {
                if (byte == self.quote) {
                    self.quote = 0;
                    self.offset += 1;
                    continue;
                }
                if (self.quote == '"' and byte == '\\' and self.offset + 1 < self.source.len) {
                    self.offset += 2;
                    return self.source[self.offset - 1];
                }
                self.offset += 1;
                return byte;
            }
            if (byte == '\'' or byte == '"') {
                self.quote = byte;
                self.offset += 1;
                continue;
            }
            if (byte == '\\' and self.offset + 1 < self.source.len) {
                self.offset += 2;
                return self.source[self.offset - 1];
            }
            self.offset += 1;
            return byte;
        }
        return null;
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn skipWhitespace(input: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < input.len and isWhitespace(input[cursor])) cursor += 1;
    return cursor;
}

fn takeWord(input: []const u8, cursor_ptr: *usize) ?Word {
    var cursor = skipWhitespace(input, cursor_ptr.*);
    if (cursor >= input.len) {
        cursor_ptr.* = cursor;
        return null;
    }
    const start = cursor;
    var quote: u8 = 0;
    var output_length: usize = 0;
    while (cursor < input.len) {
        const byte = input[cursor];
        if (quote != 0) {
            if (byte == quote) {
                quote = 0;
                cursor += 1;
            } else if (quote == '"' and byte == '\\' and cursor + 1 < input.len) {
                output_length += 1;
                cursor += 2;
            } else {
                output_length += 1;
                cursor += 1;
            }
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
            cursor += 1;
        } else if (byte == '\\' and cursor + 1 < input.len) {
            output_length += 1;
            cursor += 2;
        } else if (isWhitespace(byte)) {
            break;
        } else {
            output_length += 1;
            cursor += 1;
        }
    }
    cursor_ptr.* = cursor;
    if (output_length == 0) return null;
    return .{ .source = input[start..cursor] };
}

fn inList(word: Word, names: []const []const u8) bool {
    for (names) |name| if (word.eql(name)) return true;
    return false;
}

const read_commands = [_][]const u8{ "cat", "less", "more", "nl" };
const list_commands = [_][]const u8{
    "ls",       "eza",   "exa",     "tree",     "find",    "fd", "stat", "file", "pwd",    "realpath",
    "readlink", "which", "whereis", "basename", "dirname", "du", "df",   "id",   "whoami", "hostname",
    "uname",    "true",  "false",
};
const search_commands = [_][]const u8{ "grep", "egrep", "fgrep", "rg", "ag", "ack" };
const format_filters = [_][]const u8{
    "wc",   "sort",   "uniq",     "cut",   "tr",   "awk",  "sed",  "head",   "tail",   "tac", "rev",
    "fold", "expand", "unexpand", "paste", "comm", "join", "echo", "printf", "column",
};
const content_filters = [_][]const u8{ "echo", "printf", "tr" };

const CommandSpec = struct { name: []const u8, value_options: []const u8, required_operands: usize };
const command_specs = [_]CommandSpec{
    .{ .name = "cat", .value_options = "", .required_operands = 1 },
    .{ .name = "less", .value_options = "joP", .required_operands = 1 },
    .{ .name = "more", .value_options = "n", .required_operands = 1 },
    .{ .name = "nl", .value_options = "bdfhilnpsvw", .required_operands = 1 },
    .{ .name = "grep", .value_options = "ABCDdmef", .required_operands = 2 },
    .{ .name = "egrep", .value_options = "ABCDdmef", .required_operands = 2 },
    .{ .name = "fgrep", .value_options = "ABCDdmef", .required_operands = 2 },
    .{ .name = "rg", .value_options = "ABCmtg", .required_operands = 1 },
    .{ .name = "ag", .value_options = "ABCm", .required_operands = 1 },
    .{ .name = "ack", .value_options = "ABCm", .required_operands = 1 },
    .{ .name = "head", .value_options = "nc", .required_operands = 1 },
    .{ .name = "tail", .value_options = "nc", .required_operands = 1 },
    .{ .name = "wc", .value_options = "", .required_operands = 1 },
    .{ .name = "sort", .value_options = "kStTo", .required_operands = 1 },
    .{ .name = "uniq", .value_options = "fsw", .required_operands = 1 },
    .{ .name = "cut", .value_options = "bcdf", .required_operands = 1 },
    .{ .name = "sed", .value_options = "", .required_operands = 2 },
    .{ .name = "awk", .value_options = "", .required_operands = 2 },
    .{ .name = "tac", .value_options = "s", .required_operands = 1 },
    .{ .name = "rev", .value_options = "", .required_operands = 1 },
    .{ .name = "fold", .value_options = "w", .required_operands = 1 },
    .{ .name = "expand", .value_options = "t", .required_operands = 1 },
    .{ .name = "unexpand", .value_options = "t", .required_operands = 1 },
    .{ .name = "paste", .value_options = "d", .required_operands = 1 },
    .{ .name = "comm", .value_options = "", .required_operands = 1 },
    .{ .name = "join", .value_options = "12teoav", .required_operands = 2 },
    .{ .name = "column", .value_options = "csoN", .required_operands = 1 },
};

fn specFor(command: Word) ?CommandSpec {
    for (command_specs) |spec| if (command.eql(spec.name)) return spec;
    return null;
}

fn classifyCommand(leader: Word, subcommand: ?Word) CommandClass {
    if (inList(leader, &read_commands) or inList(leader, &search_commands) or
        inList(leader, &list_commands)) return .exploration;
    if (leader.eql("git") and subcommand != null and
        (subcommand.?.eql("grep") or subcommand.?.eql("ls-files"))) return .exploration;
    return .unknown;
}

fn isVariableAssignment(word: Word) bool {
    const first = word.byteAt(0) orelse return false;
    if (first != '_' and !std.ascii.isAlphabetic(first)) return false;
    return word.contains("=");
}

const NeutralResult = struct { body: ?usize, neutral_only: bool };
fn skipNeutralPrefix(segment: []const u8) NeutralResult {
    var cursor: usize = 0;
    var consumed = false;
    while (true) {
        var next = cursor;
        const command = takeWord(segment, &next) orelse return .{ .body = null, .neutral_only = consumed };
        var neutral = false;
        if (command.eql("cd") or command.eql("pushd")) {
            var argument_cursor = next;
            while (takeWord(segment, &argument_cursor)) |argument| {
                const first = argument.byteAt(0) orelse 0;
                if (first != '-') {
                    neutral = true;
                    break;
                }
            }
            if (!neutral) {
                neutral = true;
                argument_cursor = skipWhitespace(segment, next);
            }
            next = argument_cursor;
        } else if (command.eql("popd") or isVariableAssignment(command)) {
            neutral = true;
        } else if (command.eql("env")) {
            var argument_cursor = next;
            while (true) {
                const argument_start = argument_cursor;
                const argument = takeWord(segment, &argument_cursor) orelse break;
                if (!isVariableAssignment(argument)) {
                    argument_cursor = argument_start;
                    break;
                }
            }
            neutral = true;
            next = argument_cursor;
        }
        if (!neutral) return .{ .body = cursor, .neutral_only = false };
        consumed = true;
        cursor = skipWhitespace(segment, next);
        if (cursor >= segment.len) return .{ .body = null, .neutral_only = true };
    }
}

fn countOperands(spec: CommandSpec, body: []const u8) usize {
    var cursor: usize = 0;
    _ = takeWord(body, &cursor);
    var count: usize = 0;
    while (takeWord(body, &cursor)) |token| {
        if (token.byteAt(0) == '-' and token.byteAt(1) != null and token.byteAt(1) != '-') {
            var index: usize = 1;
            var consume_next = false;
            while (token.byteAt(index)) |option| : (index += 1) {
                if (std.mem.findScalar(u8, spec.value_options, option) != null) {
                    consume_next = token.byteAt(index + 1) == null;
                    break;
                }
            }
            if (consume_next) _ = takeWord(body, &cursor);
            continue;
        }
        if (token.byteAt(0) == '-' and token.byteAt(1) == '-' and token.byteAt(2) != null) continue;
        count += 1;
    }
    return count;
}

fn skipCommandWord(body: []const u8) usize {
    var cursor: usize = 0;
    _ = takeWord(body, &cursor);
    return cursor;
}

fn classifyXargs(body: []const u8) CommandClass {
    var cursor = skipCommandWord(body);
    while (takeWord(body, &cursor)) |token| {
        if (token.byteAt(0) != '-' or token.byteAt(1) == null) return classifyCommand(token, null);
    }
    return .unknown;
}

fn searchOptionMutates(token: Word) bool {
    const names = [_][]const u8{
        "-delete", "-exec", "-execdir", "-ok",    "-okdir",       "-fprint", "-fprint0", "-fprintf",
        "-fls",    "-x",    "-X",       "--exec", "--exec-batch",
    };
    return inList(token, &names) or token.startsWith("--exec=") or token.startsWith("--exec-batch=");
}

fn fileSearchMutates(body: []const u8) bool {
    var cursor = skipCommandWord(body);
    while (takeWord(body, &cursor)) |token| if (searchOptionMutates(token)) return true;
    return false;
}

fn hasOutputOption(body: []const u8, start: usize) bool {
    var cursor = start;
    while (takeWord(body, &cursor)) |token| {
        if ((token.byteAt(0) == '-' and token.byteAt(1) == 'o' and token.byteAt(2) != '-') or
            token.eql("--output") or token.startsWith("--output=")) return true;
    }
    return false;
}

fn sedScriptWrites(script: Word) bool {
    var iterator: ByteIterator = .{ .source = script.source };
    var previous_non_space: ?u8 = null;
    while (iterator.next()) |command| {
        if (command == 'w' or command == 'W' or command == 'e') {
            var lookahead = iterator;
            const next = lookahead.next() orelse 0;
            const valid_next = next == ' ' or next == '\t' or next == 0 or
                next == ';' or next == '\n' or next == '}';
            const valid_previous = previous_non_space == null or
                (!std.ascii.isAlphanumeric(previous_non_space.?) and previous_non_space.? != '-');
            if (valid_next and valid_previous) return true;
        }
        if (command != ' ' and command != '\t') previous_non_space = command;
    }
    return false;
}

fn awkWrites(body: []const u8, start: usize) bool {
    var cursor = start;
    while (takeWord(body, &cursor)) |token| {
        if (token.eql("-i")) {
            const extension = takeWord(body, &cursor) orelse return false;
            if (extension.eql("inplace")) return true;
            continue;
        }
        if ((token.startsWith("-i") and token.byteAt(2) != null and wordSuffixEquals(token, 2, "inplace")) or
            token.contains("system(")) return true;
    }
    return false;
}

fn wordSuffixEquals(word: Word, skip: usize, expected: []const u8) bool {
    var iterator: ByteIterator = .{ .source = word.source };
    var index: usize = 0;
    while (index < skip) : (index += 1) _ = iterator.next() orelse return false;
    for (expected) |byte| if ((iterator.next() orelse return false) != byte) return false;
    return iterator.next() == null;
}

fn sedFilterWrites(body: []const u8, start: usize) bool {
    var cursor = start;
    while (takeWord(body, &cursor)) |token| if (sedScriptWrites(token)) return true;
    return false;
}

fn pagerWrites(body: []const u8) bool {
    var cursor = skipCommandWord(body);
    while (takeWord(body, &cursor)) |token| {
        const second = token.byteAt(1);
        if ((token.byteAt(0) == '-' and (second == 'o' or second == 'O') and token.byteAt(2) != '-') or
            token.eql("--log-file") or token.startsWith("--log-file=")) return true;
    }
    return false;
}

fn sedEditsInPlace(body: []const u8) bool {
    var cursor = skipCommandWord(body);
    while (takeWord(body, &cursor)) |token| {
        if (token.startsWith("--in-place")) return true;
        if (token.byteAt(0) == '-' and token.byteAt(1) != '-' and token.byteAt(1) != null) {
            var index: usize = 1;
            while (token.byteAt(index)) |byte| : (index += 1) {
                if (byte == '.') break;
                if (byte == 'i') return true;
            }
        }
    }
    return false;
}

fn knownCommandWrites(command: Word, body: []const u8) bool {
    if ((command.eql("find") or command.eql("fd")) and fileSearchMutates(body)) return true;
    if (command.eql("tree") and hasOutputOption(body, skipCommandWord(body))) return true;
    return (command.eql("less") or command.eql("more")) and pagerWrites(body);
}

fn formatFilterWrites(command: Word, body: []const u8) bool {
    const arguments = skipCommandWord(body);
    if (command.eql("sort")) return hasOutputOption(body, arguments);
    if (command.eql("awk")) return awkWrites(body, arguments);
    if (command.eql("sed")) return sedFilterWrites(body, arguments);
    return false;
}

fn classifyFormatFilter(command: Word, body: []const u8) CommandClass {
    if (inList(command, &content_filters)) return .filter;
    const spec = specFor(command) orelse return .unknown;
    if (countOperands(spec, body) < spec.required_operands) return .filter;
    if (formatFilterWrites(command, body)) return .unknown;
    return .exploration;
}

fn classifySegment(segment: []const u8) CommandClass {
    const neutral = skipNeutralPrefix(segment);
    if (neutral.neutral_only) return .exploration;
    const body_start = neutral.body orelse return .unknown;
    const body = segment[body_start..];
    var cursor: usize = 0;
    const command = takeWord(body, &cursor) orelse return .unknown;
    const subcommand = takeWord(body, &cursor);
    var classification = classifyCommand(command, subcommand);
    if (classification != .unknown) {
        if (knownCommandWrites(command, body)) return .unknown;
        if (specFor(command)) |spec| if (countOperands(spec, body) < spec.required_operands) return .filter;
    } else if (command.eql("xargs")) {
        classification = classifyXargs(body);
    } else if (command.eql("sed") and sedEditsInPlace(body)) {
        classification = .unknown;
    } else if (inList(command, &format_filters)) {
        classification = classifyFormatFilter(command, body);
    }
    return classification;
}

fn allowedStderrRedirectEnd(command: []const u8, offset: usize) usize {
    const prefix = offset >= 1 and command[offset - 1] == '2' and
        (offset == 1 or std.mem.findScalar(u8, " \t\n\r&|;", command[offset - 2]) != null);
    if (!prefix) return 0;
    if (offset + 2 < command.len and command[offset + 1] == '&' and command[offset + 2] == '1')
        return offset + 3;
    var target = offset + 1;
    while (target < command.len and (command[target] == ' ' or command[target] == '\t')) target += 1;
    if (target + 9 <= command.len and std.mem.eql(u8, command[target .. target + 9], "/dev/null"))
        return target + 9;
    return 0;
}

fn hasDisqualifier(command: []const u8) bool {
    var quote: u8 = 0;
    var offset: usize = 0;
    while (offset < command.len) : (offset += 1) {
        const byte = command[offset];
        if (quote != 0) {
            if (quote == '"' and byte == '\\' and offset + 1 < command.len) {
                offset += 1;
                continue;
            }
            if (byte == quote) {
                quote = 0;
                continue;
            }
            if (quote == '"' and (byte == '`' or (byte == '$' and offset + 1 < command.len and
                command[offset + 1] == '('))) return true;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '\\' and offset + 1 < command.len) {
            offset += 1;
            continue;
        }
        if (byte == '`' or (byte == '$' and offset + 1 < command.len and command[offset + 1] == '(')) return true;
        if ((byte == '<' or byte == '>') and offset + 1 < command.len and command[offset + 1] == '(') return true;
        if (byte == '<' and offset + 1 < command.len and command[offset + 1] == '<') return true;
        if (byte == '&' and (offset + 1 >= command.len or command[offset + 1] != '&') and
            (offset == 0 or (command[offset - 1] != '>' and command[offset - 1] != '&'))) return true;
        if (byte == '>') {
            const redirect_end = allowedStderrRedirectEnd(command, offset);
            if (redirect_end == 0) return true;
            offset = redirect_end - 1;
        }
    }
    return false;
}

/// Conservatively classifies a shell command as read-only exploration.
/// The check is lexical, allocation-free, and intentionally may reject safe shell syntax.
pub fn isExploration(command: []const u8) bool {
    if (skipWhitespace(command, 0) == command.len or hasDisqualifier(command)) return false;
    var has_substantive = false;
    var statement_has_producer = false;
    var segment_start: usize = 0;
    var previous: Separator = .start;
    var quote: u8 = 0;
    var offset: usize = 0;
    while (offset <= command.len) {
        var separator_length: usize = 0;
        var separator: Separator = .statement;
        if (offset < command.len) {
            const byte = command[offset];
            if (quote != 0) {
                if (quote == '"' and byte == '\\' and offset + 1 < command.len) {
                    offset += 2;
                    continue;
                }
                if (byte == quote) quote = 0;
                offset += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                offset += 1;
                continue;
            }
            if (byte == '\\' and offset + 1 < command.len) {
                offset += 2;
                continue;
            }
            if ((byte == '&' or byte == '|') and offset + 1 < command.len and command[offset + 1] == byte) {
                separator_length = 2;
            } else if (byte == ';' or byte == '\n' or byte == '\r') {
                separator_length = 1;
            } else if (byte == '|') {
                separator_length = 1;
                separator = .pipe;
            } else {
                offset += 1;
                continue;
            }
        }
        if (previous != .pipe) statement_has_producer = false;
        const segment = command[segment_start..offset];
        if (skipWhitespace(segment, 0) < segment.len) {
            switch (classifySegment(segment)) {
                .unknown => return false,
                .filter => if (!statement_has_producer) return false,
                .exploration => {
                    statement_has_producer = true;
                    has_substantive = true;
                },
            }
        }
        if (offset == command.len) break;
        previous = separator;
        segment_start = offset + separator_length;
        offset += separator_length;
    }
    return has_substantive;
}

test "exploration classification matches hax lexical boundary" {
    const yes = [_][]const u8{
        "ls",
        "ls -la",
        "pwd",
        "cat foo.c",
        "find . -name '*.c'",
        "grep -r foo src",
        "rg pattern",
        "git ls-files",
        "git grep TODO",
        "head foo.c",
        "wc -l foo.c",
        "grep -r foo src | head -20",
        "find . -type f | sort | uniq",
        "cd /tmp && find . -name foo",
        "env LC_ALL=C grep foo bar.c",
        "find . -name foo 2>/dev/null",
        "grep -r foo src 2>&1 | head",
        "find . -print",
        "sort in.txt",
        "rg foo | sort -u",
        "awk '{print > \"f\"}' file.txt",
        "sed '1w out' file.txt",
        "awk '{print system_var}' file.txt",
        "sed -n '1,20p' foo.c",
        "awk -i tools.awk '{print}' file.txt",
        "tree -L 2",
        "less foo.c",
        "find . -type f | xargs cat",
        "grep '$(touch /tmp/x)' file.c",
        "grep \"\\$(notrun) literal\" file.c",
        "grep 'foo\\bar' file.c",
        "grep \"foo\\\"bar\" file.c",
        "cd /tmp",
        "grep '>foo' bar.c",
        "cat foo | sed -n '1,20p'",
        "cat foo.c | wc -l",
        "rg pattern | tail -n 5",
        "find . | cat",
        "head -n 20 foo.c",
        "cat foo.c | head -n 5",
        "cat foo.c | wc -l | head",
        "ls\npwd",
        "ls\r\npwd",
        "grep 'foo\nbar' file.c",
        "wc -l < foo.c",
    };
    for (yes) |command| try std.testing.expect(isExploration(command));

    const no = [_][]const u8{
        "",
        "   ",
        "git status",
        "rm foo",
        "cargo build",
        "find . && rm bar",
        "sed -i 's/x/y/' file.c",
        "sed -Ei.bak 's/x/y/' file.c",
        "cat foo | tee out.txt",
        "find . -delete",
        "fd --exec=rm",
        "sort -o out.txt in.txt",
        "sort | head",
        "awk '{system(\"touch /tmp/x\")}' file.txt",
        "sed -n 'w out' file.txt",
        "sed 's/x/y/e' file.txt",
        "awk -i inplace '{print}' file.txt",
        "awk '{print $1}'",
        "tree -o out.txt",
        "less --log-file copy.txt input.txt",
        "ls & rm file",
        "python2 >/dev/null",
        "ls > out.txt",
        "cat <<EOF\nhi\nEOF",
        "echo $(date)",
        "ls `pwd`",
        "echo \"$(touch /tmp/x)\"",
        "grep 'foo\\' ; rm victim; echo 'bar' file",
        "echo",
        "printf 'hi\\n'",
        "wc -l",
        "yes | head -10",
        "cat",
        "grep TODO",
        "head -n 20",
        "cut -d : -f 1",
        "ls; sort",
        "ls && cat",
        "find . | sort; wc -l",
        "ls; | sort",
        "cat foo\nrm bar",
    };
    for (no) |command| try std.testing.expect(!isExploration(command));
}
