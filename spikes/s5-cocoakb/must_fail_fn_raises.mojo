# An fn may not raise: the C boundary has no Mojo error channel.
fn bad() raises -> Int:
    raise Error("no")


def main() raises:
    _ = bad()
