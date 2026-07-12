"""Small fixture inspected by the model during the first SDK turn."""


def run() -> str:
    return "fixture-ok"


if __name__ == "__main__":
    print(run())
