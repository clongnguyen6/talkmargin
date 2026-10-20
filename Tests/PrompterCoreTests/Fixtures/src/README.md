Fixture sources. Rebuild with:

    scripts/dev/make-docx.sh Tests/PrompterCoreTests/Fixtures/src/word-notes Tests/PrompterCoreTests/Fixtures/word-notes.docx
    scripts/dev/make-docx.sh Tests/PrompterCoreTests/Fixtures/src/no-document Tests/PrompterCoreTests/Fixtures/no-document.docx
    scripts/dev/make-docx.sh Tests/PrompterCoreTests/Fixtures/src/bad-xml Tests/PrompterCoreTests/Fixtures/bad-xml.docx
    scripts/dev/make-docx.sh Tests/PrompterCoreTests/Fixtures/src/bad-levels Tests/PrompterCoreTests/Fixtures/bad-levels.docx
    textutil -convert docx -format html Tests/PrompterCoreTests/Fixtures/src/direct-format.html -output Tests/PrompterCoreTests/Fixtures/direct-format.docx

`word-notes` mirrors Word's own package layout (styles.xml with outline
levels, numbering.xml with a byte order mark, content controls, tracked
changes). `direct-format` is macOS textutil output: no styles at all, only
direct formatting.

`bad-levels` carries out-of-range numbers (negative or huge outline levels,
list levels, starts, sizes); loading must not crash.
