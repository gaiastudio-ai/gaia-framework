# Test fixture — violates string 3 (backtick variant)

This fixture intentionally contains the backtick variant of string 3:

The `Agent`-tool subagent dispatch primitive not surfaced in this fork's tool set.

The backtick-tolerant regex catches the variant above; a literal-string match
would not.
