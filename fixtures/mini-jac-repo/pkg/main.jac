def used(x: int) -> int {
    return x + 1;
}

def never_called(x: int) -> int {
    return x * 999;
}

with entry {
    print(used(1));
}
