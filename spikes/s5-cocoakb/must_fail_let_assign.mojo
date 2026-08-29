# A let binding cannot be reassigned.
def main() raises:
    let x = 1
    x = 2
    print(x)
