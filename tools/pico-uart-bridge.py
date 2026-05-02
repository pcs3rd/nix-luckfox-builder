# pico-uart-bridge.py
# Save this as main.py on the Pico — it runs automatically on boot.
#
# Wiring:
#   Pico GP0 (TX, pin 1) → Luckfox RXD
#   Pico GP1 (RX, pin 2) ← Luckfox TXD
#   Pico GND             → Luckfox GND
#
# Usage:
#   Copy to Pico as main.py (use Thonny or: mpremote cp this.py :main.py)
#   Open serial port at 115200: screen /dev/tty.usbmodem* 115200
#   Ctrl+C stops the bridge and returns to MicroPython REPL.

import machine
import sys
import select
import micropython

micropython.kbd_intr(-1)

# Onboard LED: on = bridge running
led = machine.Pin("LED", machine.Pin.OUT)
led.on()

uart = machine.UART(0, baudrate=115200, tx=machine.Pin(0), rx=machine.Pin(1))

# poll() is more reliable than select.select() for USB stdin on the Pico
poll = select.poll()
poll.register(sys.stdin, select.POLLIN)

sys.stdout.write("\r\nLuckfox serial bridge ready — Ctrl+C to stop\r\n")

try:
    while True:
        # Luckfox → computer: drain UART RX buffer to USB
        n = uart.any()
        if n:
            sys.stdout.buffer.write(uart.read(n))

        # Computer → Luckfox: forward any USB input to UART TX
        if poll.poll(0):
            c = sys.stdin.buffer.read(1)
            if c:
                uart.write(c)

except KeyboardInterrupt:
    led.off()
    sys.stdout.write("\r\nBridge stopped.\r\n")
