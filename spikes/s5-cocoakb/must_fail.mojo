# A name the metadata does not know is a COMPILE error, not a wrong answer.
from std.sys._cocoakb import cocoakb_struct_size


def main():
    comptime bogus = cocoakb_struct_size["NSDefinitelyNotAStruct"]()
    print(bogus)
