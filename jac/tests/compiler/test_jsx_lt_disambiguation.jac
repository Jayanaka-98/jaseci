"""Minimal reproduction for JSX vs less-than disambiguation bug.

The lexer previously could not distinguish `<` as a comparison operator from
`<` as the start of a JSX opening tag. Any expression of the form
`identifier<identifier` (e.g., `i<points.length`) was misinterpreted as a JSX
tag `<points`, causing an infinite loop in the lexer's mode state machine.

Bug: The lexer saw `<` followed by an alpha character and unconditionally
entered JSX_TAG mode, even when `<` appeared in an expression context
(after a NAME, number, closing paren, etc.).

Fix: Added `prev_token_kind` tracking and a `can_start_jsx()` guard that
treats `<` as a comparison operator when the previous token can end an
expression.
"""

import from jaclang.jac0core.parser { parse as rd_parse }
import from jaclang.jac0core.parser.lexer { tokenize }
import from jaclang.jac0core.parser.tokens { TokenKind }

# --- Lexer-level tests: comparison operator must NOT trigger JSX ---

test "comparison i<points should tokenize as LT not JSX" {
    # This is the exact pattern that caused the infinite loop in
    # filter_executor.cl.jac: `for i=0 to i<points.length by i+=1`
    (tokens, errors) = tokenize("i<points");
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens if t.kind != TokenKind.EOF];
    # Should be: NAME("i"), LT, NAME("points")
    assert kinds == [TokenKind.NAME, TokenKind.LT, TokenKind.NAME],
        f"Expected [NAME, LT, NAME] but got {kinds}";
}

test "comparison in for-loop should not trigger JSX" {
    # Full for-loop pattern from the bug
    source = "for i=0 to i<points.length by i+=1 { x = i; }";
    (tokens, errors) = tokenize(source);
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens];
    assert TokenKind.LT in kinds, "Expected LT token in for-loop comparison";
    assert TokenKind.JSX_OPEN_START not in kinds, "JSX_OPEN_START should not appear in for-loop";
}

test "number comparison n<limit should tokenize as LT" {
    (tokens, errors) = tokenize("n<limit");
    assert not errors;
    kinds = [t.kind for t in tokens if t.kind != TokenKind.EOF];
    assert kinds == [TokenKind.NAME, TokenKind.LT, TokenKind.NAME];
}

test "paren comparison (x)<y should tokenize as LT" {
    (tokens, errors) = tokenize("(x)<y");
    assert not errors;
    kinds = [t.kind for t in tokens if t.kind != TokenKind.EOF];
    assert kinds == [TokenKind.LPAREN, TokenKind.NAME, TokenKind.RPAREN,
                     TokenKind.LT, TokenKind.NAME];
}

test "bracket comparison arr[0]<limit should tokenize as LT" {
    (tokens, errors) = tokenize("arr[0]<limit");
    assert not errors;
    kinds = [t.kind for t in tokens if t.kind != TokenKind.EOF];
    assert TokenKind.LT in kinds, "Expected LT after ]";
    assert TokenKind.JSX_OPEN_START not in kinds;
}

test "string comparison s<t should tokenize as LT" {
    (tokens, errors) = tokenize('"hello"<t');
    assert not errors;
    kinds = [t.kind for t in tokens if t.kind != TokenKind.EOF];
    assert TokenKind.LT in kinds;
    assert TokenKind.JSX_OPEN_START not in kinds;
}

# --- Lexer-level tests: JSX must still work after non-expression tokens ---

test "JSX after assignment is still JSX" {
    source = "x = <div>text</div>";
    (tokens, errors) = tokenize(source);
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens];
    assert TokenKind.JSX_OPEN_START in kinds, "Expected JSX_OPEN_START after =";
}

test "JSX after open paren is still JSX" {
    source = "foo(<span>hi</span>)";
    (tokens, errors) = tokenize(source);
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens];
    assert TokenKind.JSX_OPEN_START in kinds, "Expected JSX_OPEN_START after (";
}

test "nested JSX inside JSX content is still JSX" {
    source = "<div><span>inner</span></div>";
    (tokens, errors) = tokenize(source);
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens];
    jsx_opens = [k for k in kinds if k == TokenKind.JSX_OPEN_START];
    assert len(jsx_opens) == 2, f"Expected 2 JSX_OPEN_START tokens, got {len(jsx_opens)}";
}

test "JSX after comma in array is still JSX" {
    source = "[<div>a</div>, <span>b</span>]";
    (tokens, errors) = tokenize(source);
    assert not errors, f"Unexpected lexer errors: {errors}";
    kinds = [t.kind for t in tokens];
    jsx_opens = [k for k in kinds if k == TokenKind.JSX_OPEN_START];
    assert len(jsx_opens) == 2, f"Expected 2 JSX_OPEN_START, got {len(jsx_opens)}";
}

# --- Parser-level tests: full parse of mixed comparison + JSX ---

test "for-loop with comparison parses without errors" {
    source = '''
    cl {
        def foo() -> any {
            points = [1, 2, 3];
            for i=0 to i<points.length by i+=1 {
                x = points[i];
            }
            return <div>done</div>;
        }
    }
    ''';
    (module, parse_errors, lex_errors) = rd_parse(source, "<test>");
    assert not lex_errors, f"Lex errors: {lex_errors}";
    assert not parse_errors, f"Parse errors: {parse_errors}";
}

test "mixed comparison and JSX in same function parses correctly" {
    source = '''
    cl {
        def render(items: list) -> any {
            count = items.length;
            if count<limit {
                return <div>under limit</div>;
            }
            return <span>over</span>;
        }
    }
    ''';
    (module, parse_errors, lex_errors) = rd_parse(source, "<test>");
    assert not lex_errors, f"Lex errors: {lex_errors}";
    assert not parse_errors, f"Parse errors: {parse_errors}";
}
