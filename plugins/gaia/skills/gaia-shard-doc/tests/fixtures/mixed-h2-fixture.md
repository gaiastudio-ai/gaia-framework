# Synthetic Mixed-H2 Fixture (E53-S236)

This fixture contains exactly **5 real H2 headings** and **5 H2-shaped lines
inside fenced code blocks** that must be ignored by a code-block-aware parser.

Used by `tests/parse-h2-boundaries.bats` to verify AC1, AC2, AC3.

## Real Section One

Body content for section one.

```markdown
## Fake Heading Inside Code Block A
Some example markdown.
```

## Real Section Two

Body content for section two.

```
## Fake Heading Inside Code Block B
Plain fenced block (no language tag).
```

## Real Section Three

Body content for section three. The next code block embeds two
fake H2 headings — both must be skipped.

```markdown
## Fake Heading Inside Code Block C
Body of example.

## Fake Heading Inside Code Block D
More example body.
```

## Real Section Four

Body content for section four.

```text
## Fake Heading Inside Code Block E
Text fence (no markdown rendering).
```

## Real Section Five

Body content for section five — final real H2.
