# Test fixture — violates string 3 (literal-hyphen variant)

This fixture intentionally contains the literal-hyphen variant of string 3:

The Agent-tool subagent dispatch primitive not surfaced in this fork's tool set.

It MUST trip the assessment-doc-bypass-check scanner via the regex
`Agent.{0,2}tool subagent dispatch primitive not surfaced`.
