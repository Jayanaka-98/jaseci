import from time { sleep }

walker CodeWriter {
    has name: str = "writer";

    can write with entry {
        sleep(1);
        print("CodeWriter ran:", self.name);
    }
}

with entry {
    sub_a1 = flow root spawn CodeWriter();
    print("dispatched, main continues");
    wait sub_a1;
    print("joined");
}
