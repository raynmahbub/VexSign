# Translating VexSign

Thanks for helping make VexSign usable in more languages. Translations live in
[`App/iOS/VexSign/Resources/Localizable.xcstrings`](App/iOS/VexSign/Resources/Localizable.xcstrings),
a standard Xcode String Catalog. The catalog's source language is English; the
currently represented locales include Arabic, Czech, German, Spanish, French,
Indonesian, Italian, Polish, Russian, Turkish, Vietnamese, and Simplified
Chinese. A locale can be improved or completed through a pull request.

## Contribute a translation

1. Check the catalog and existing pull requests for the locale. Agree on a
   consistent tone and terminology with existing translations where possible.
2. Use Xcode's String Catalog editor, or carefully edit the JSON while
   preserving the catalog structure. Add or update only your locale's
   `localizations` entries; do not change English source strings to make them
   easier to translate.
3. Translate the **value**, not the key. Keep format placeholders such as
   `%@`, `%lld`, `%1$@`, and escaped sequences intact, and preserve any
   punctuation or whitespace required by the surrounding sentence.
4. Leave intentionally non-translatable identifiers, URLs, file extensions,
   command names, and product names unchanged unless the context calls for a
   standard localized form.
5. Review plurals, gender/variation forms, accessibility labels, and text that
   may appear in narrow buttons or large Dynamic Type. Prefer clear, natural
   phrasing over word-for-word translation.
6. Run the checks below and open a PR describing the locale and the areas
   translated. Native speakers are especially welcome to review existing
   entries and report awkward or ambiguous source wording.

Machine translation can be a starting point, but should be reviewed by a fluent
speaker before it is submitted. Do not translate the full JSON with a bulk
replacement that may change keys, placeholders, or Xcode's metadata.

## Validation

From the repository root:

```sh
python3 Tools/Development/sync-strings.py --check
make verify
```

The sync check verifies that source literals have catalog keys; it does not
prove the quality or completeness of translated values. The weekly localization
maintenance automation may add missing English entries and prune unused keys,
so avoid unrelated catalog-wide formatting changes. Do not remove keys just
because they appear unused without checking the source and recent changes.

## Questions and terminology

If an English string is unclear, add context in the PR rather than guessing at a
translation. Include the screen or feature where it appears when possible. Do
not include certificates, private keys, provisioning profiles, passwords,
tokens, UDIDs, or diagnostic archives in translation issues or pull requests.

See [Contributing](CONTRIBUTING.md) for the general contribution process and
[Security](SECURITY.md) for private vulnerability reporting.
