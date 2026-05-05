# Top-level Document

Some preamble prose that lives above the first H3 boundary. This becomes
`_preamble.md` after sharding.

## Section A (H2 — ignored by H3 sharder)

Prose that belongs to the preamble because it sits above the first H3.

### Alpha Section

Body content for the Alpha section. Paragraph one.

Paragraph two of Alpha — still inside the same shard.

### Beta Section

Body content for the Beta section.

- bullet one
- bullet two

### Gamma Section

Closing section — the last shard captures every line through end-of-file.

Final paragraph — trailing prose lives in the Gamma shard.
