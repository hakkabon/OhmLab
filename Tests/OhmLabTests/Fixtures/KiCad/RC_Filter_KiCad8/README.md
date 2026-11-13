# RC_Filter KiCad 8.0 corpus entry

The same three-level RC filter as the KiCad 10 fixture, with the schematic
format version set to `20231120` and generator version `8.0`.


This entry proves that reading, preservation, and value edits are driven by the
S-expression structure rather than by a single KiCad release number. It is not a
byte-for-byte reproduction of a KiCad 8.0 drawing and does not claim that
every KiCad 8.0 construct is supported.

`expected.cir` is unchanged from the KiCad 10 fixture because the electrical
content is the same.

`Tests/OhmLabTests/KiCadVersionCorpusTests.swift` reads this entry, checks an
untouched preservation round-trip, and patches one value. Regenerate it from the
KiCad 10 fixture with `python3 ../generate_version_variants.py`.
