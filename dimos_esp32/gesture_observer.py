"""Print decoded messages from the gesture blueprint in a separate process."""

from __future__ import annotations

import json
import argparse
import sys
import threading

from dimos.core.transport_factory import make_transport
from dimos.msgs.std_msgs.String import String


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", action="store_true", help="also read /go2_control_status")
    args = parser.parse_args()
    output_lock = threading.Lock()

    def write_line(text: str) -> None:
        # Different topic callbacks can run concurrently. print() may write its
        # text and newline separately, joining two JSON objects on one line.
        with output_lock:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()

    subscriptions = []
    try:
        topics = ["/esp32_gestures", "/esp32_status"]
        if args.control:
            topics.append("/go2_control_status")
        for topic in topics:
            transport = make_transport(topic, String)

            def receive(message: String, topic: str = topic) -> None:
                write_line(json.dumps({"topic": topic, "data": json.loads(message.data)}))

            subscriptions.append(transport.subscribe(receive))
        write_line("Listening for decoded ESP32 dimOS messages; Ctrl+C to stop.")
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        for unsubscribe in reversed(subscriptions):
            unsubscribe()


if __name__ == "__main__":
    main()
