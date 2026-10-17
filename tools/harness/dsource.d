// Shared D code view without filesystem projections or their test fixtures.
module tools.harness.dsource;

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

string blankNonCode(string src, bool keepComments = false) {
    auto outBuf = new char[src.length];
    foreach (i, c; src) outBuf[i] = (c == '\n') ? '\n' : ' ';
    size_t codeStart = 0;
    void keep(size_t a, size_t b) {
        foreach (k; a .. b) if (src[k] != '\n') outBuf[k] = src[k];
    }
    // Blank [a, b) by closing the kept run before it and reopening after.
    void drop(size_t a, size_t b) { keep(codeStart, a); codeStart = b; }

    size_t i = 0;
    while (i < src.length) {
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            const size_t s = i;
            while (i < src.length && src[i] != '\n') ++i;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            const size_t s = i;
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) ++i;
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            if (!keepComments) drop(s, i);
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') {
            const size_t s = i;
            int depth = 0;
            while (i < src.length) {
                if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') { ++depth; i += 2; continue; }
                if (i + 1 < src.length && src[i] == '+' && src[i + 1] == '/') { --depth; i += 2; if (depth == 0) break; continue; }
                ++i;
            }
            if (!keepComments) drop(s, i);
            continue;
        }
        // TOKEN and WYSIWYG strings, before the plain `"` handler — they open
        // on a LETTER, so by the time the walker reaches the quote the prefix
        // is already behind it. See the block comment above for what was
        // measured and why this is not the "no such literal here" claim it
        // replaced.
        if ((src[i] == 'q' || src[i] == 'r')
            && (i == 0 || !isIdentChar(src[i - 1]))
            && i + 1 < src.length) {
            // `r"…"` — wysiwyg, no escape processing at all.
            if (src[i] == 'r' && src[i + 1] == '"') {
                const size_t s = i;
                i += 2;
                while (i < src.length && src[i] != '"') ++i;
                i = (i + 1 <= src.length) ? i + 1 : src.length;
                drop(s, i);
                continue;
            }
            // `q{…}` — token string, braces NEST.
            if (src[i] == 'q' && src[i + 1] == '{') {
                const size_t s = i;
                i += 2;
                int depth = 1;
                while (i < src.length && depth > 0) {
                    if (src[i] == '{') ++depth;
                    else if (src[i] == '}') --depth;
                    ++i;
                }
                drop(s, i);
                continue;
            }
            // `q"…"` — delimited. Bracket forms nest; anything else is the
            // heredoc form, closed by `<ident>"` on its own.
            if (src[i] == 'q' && src[i + 1] == '"') {
                const size_t s = i;
                const char open = (i + 2 < src.length) ? src[i + 2] : '\0';
                char close = '\0';
                switch (open) {
                    case '(': close = ')'; break;
                    case '[': close = ']'; break;
                    case '<': close = '>'; break;
                    case '{': close = '}'; break;
                    default:  break;
                }
                if (close != '\0') {
                    i += 3;
                    int depth = 1;
                    while (i < src.length && depth > 0) {
                        if (src[i] == open) ++depth;
                        else if (src[i] == close) --depth;
                        ++i;
                    }
                    if (i < src.length && src[i] == '"') ++i;
                } else {
                    // q"IDENT\n … \nIDENT"
                    size_t t = i + 2;
                    while (t < src.length && isIdentChar(src[t])) ++t;
                    const string tag = src[i + 2 .. t];
                    i = t;
                    if (tag.length) {
                        const string term = tag ~ "\"";
                        while (i + term.length <= src.length
                               && src[i .. i + term.length] != term) ++i;
                        i = (i + term.length <= src.length)
                            ? i + term.length : src.length;
                    }
                }
                drop(s, i);
                continue;
            }
        }
        if (src[i] == '"') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '`') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '`') ++i;
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        if (src[i] == '\'') {
            const size_t s = i;
            ++i;
            while (i < src.length && src[i] != '\'') {
                if (src[i] == '\\' && i + 1 < src.length) ++i;
                ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            drop(s, i);
            continue;
        }
        ++i;
    }
    keep(codeStart, src.length);
    return cast(string)outBuf;
}
