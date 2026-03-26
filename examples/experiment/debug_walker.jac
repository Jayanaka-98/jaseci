"""Minimal walker test."""

node StepA {
    has label: str = "A";
}

node StepB {
    has label: str = "B";
}

walker TestWalker {
    has visited: list[str] = [];

    can at_a with StepA entry {
        print(f"At {here.label}");
        self.visited.append(here.label);
        visit [-->];
    }

    can at_b with StepB entry {
        print(f"At {here.label}");
        self.visited.append(here.label);
    }
}

glob a = StepA(),
     b = StepB();

with entry {
    a ++> b;
}

glob w = a spawn TestWalker();

with entry {
    print(f"Visited: {w.visited}");
}
