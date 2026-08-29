import os
import random
import time
import urllib.error
import urllib.request


TARGET_URL = os.getenv("TARGET_URL", "http://otel-python")
REQUEST_INTERVAL = float(os.getenv("REQUEST_INTERVAL", "5"))
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "10"))

ENDPOINTS = [
    "/",
    "/work",
    "/call-external",
    "/error",
]


def request(endpoint: str) -> None:
    url = f"{TARGET_URL.rstrip('/')}{endpoint}"

    started = time.monotonic()

    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT) as response:
            status = response.status
            duration = time.monotonic() - started

            print(
                f"request method=GET path={endpoint} "
                f"status={status} duration={duration:.3f}s",
                flush=True,
            )

    except urllib.error.HTTPError as exc:
        duration = time.monotonic() - started

        print(
            f"request method=GET path={endpoint} "
            f"status={exc.code} duration={duration:.3f}s",
            flush=True,
        )

    except Exception as exc:
        duration = time.monotonic() - started

        print(
            f"request method=GET path={endpoint} "
            f"status=ERROR duration={duration:.3f}s error={exc}",
            flush=True,
        )


def main() -> None:
    print("Traffic generator starting", flush=True)
    print(f"TARGET_URL={TARGET_URL}", flush=True)
    print(f"REQUEST_INTERVAL={REQUEST_INTERVAL}s", flush=True)
    print(f"REQUEST_TIMEOUT={REQUEST_TIMEOUT}s", flush=True)

    while True:
        endpoint = random.choice(ENDPOINTS)

        request(endpoint)

        time.sleep(REQUEST_INTERVAL)


if __name__ == "__main__":
    main()
