import asyncio
from asyncio import Task, TaskGroup
from pathlib import Path
import re
from typing import Optional, Union

from adafruit_hid.consumer_control import ConsumerControl
from adafruit_hid.digitizer import Digitizer
from adafruit_hid.gamepad import Gamepad
from adafruit_hid.keyboard import Keyboard
from adafruit_hid.mouse import Mouse
from evdev import (
    InputDevice,
    InputEvent,
    KeyEvent,
    RelEvent,
    AbsEvent,
    categorize,
    list_devices,
)
import pyudev
import usb_hid
from usb_hid import Device


from .evdev import (
    ecodes,
    evdev_to_usb_hid,
    find_key_name,
    get_mouse_movement,
    is_consumer_key,
    is_keyboard_key,
    is_mouse_button,
    is_gamepad_button,
    is_digitizer_button,
    is_gamepad_event,
    is_digitizer_event,
    scale_axis_value,
    GAMEPAD_AXIS_MAP,
    DIGITIZER_AXIS_MAP,
)
from .logging import get_logger

_logger = get_logger()


class GadgetManager:
    """
    Manages enabling, disabling, and references to USB HID gadget devices.

    :ivar _gadgets: Internal dictionary mapping device types to HID device objects
    :ivar _enabled: Indicates whether the gadgets have been enabled
    """

    def __init__(self) -> None:
        """
        Initialize without enabling devices. Call enable_gadgets() to enable them.
        """
        self._gadgets = {
            "keyboard": None,
            "mouse": None,
            "consumer": None,
            "gamepad": None,
            "digitizer": None,
        }
        self._enabled = False

    def enable_gadgets(self) -> None:
        """
        Disable and re-enable usb_hid devices, then store references
        to the new Keyboard, Mouse, and ConsumerControl gadgets.
        """
        try:
            usb_hid.disable()
        except Exception as ex:
            _logger.debug(f"usb_hid.disable() failed or was already disabled: {ex}")

        usb_hid.enable(
            [
                Device.BOOT_MOUSE,
                Device.KEYBOARD,
                Device.CONSUMER_CONTROL,
                Device.GAMEPAD,
                #  Device.DIGITIZER,
            ]
        )  # type: ignore
        enabled_devices = list(usb_hid.devices)  # type: ignore

        self._gadgets["keyboard"] = Keyboard(enabled_devices)
        self._gadgets["mouse"] = Mouse(enabled_devices)
        self._gadgets["consumer"] = ConsumerControl(enabled_devices)
        self._gadgets["gamepad"] = Gamepad(enabled_devices)
        # self._gadgets["digitizer"] = Digitizer(enabled_devices)
        self._enabled = True

        _logger.debug(f"USB HID gadgets re-initialized: {enabled_devices}")

    def get_keyboard(self) -> Optional[Keyboard]:
        """
        Get the Keyboard gadget.

        :return: A Keyboard object, or None if not initialized
        :rtype: Keyboard | None
        """
        return self._gadgets.get("keyboard") if self._enabled else None

    def get_mouse(self) -> Optional[Mouse]:
        """
        Get the Mouse gadget.

        :return: A Mouse object, or None if not initialized
        :rtype: Mouse | None
        """
        return self._gadgets.get("mouse") if self._enabled else None

    def get_consumer(self) -> Optional[ConsumerControl]:
        """
        Get the ConsumerControl gadget.

        :return: A ConsumerControl object, or None if not initialized
        :rtype: ConsumerControl | None
        """
        return self._gadgets.get("consumer") if self._enabled else None

    def get_gamepad(self) -> Optional[Gamepad]:
        """Get the Gamepad gadget if enabled."""
        return self._gadgets.get("gamepad") if self._enabled else None

    def get_digitizer(self) -> Optional[Digitizer]:
        """Get the Digitizer gadget if enabled."""
        return self._gadgets.get("digitizer") if self._enabled else None


class ShortcutToggler:
    """
    Tracks a user-defined shortcut and toggles relaying on/off when the shortcut is pressed.
    """

    def __init__(
        self,
        shortcut_keys: set[str],
        relaying_active: asyncio.Event,
        gadget_manager: GadgetManager,
    ) -> None:
        """
        :param shortcut_keys: A set of evdev-style key names to detect
        :param relaying_active: An asyncio.Event controlling whether relaying is active
        :param gadget_manager: GadgetManager to release keyboard/mouse states on toggle
        """
        self.shortcut_keys = shortcut_keys
        self.relaying_active = relaying_active
        self.gadget_manager = gadget_manager

        self.currently_pressed: set[str] = set()

    def handle_key_event(self, event: KeyEvent) -> None:
        """
        Process a key press or release to detect the toggle shortcut.

        :param event: The incoming KeyEvent from evdev
        :type event: KeyEvent
        """
        key_name = find_key_name(event)
        if key_name is None:
            return

        if event.keystate == KeyEvent.key_down:
            self.currently_pressed.add(key_name)
        elif event.keystate == KeyEvent.key_up:
            self.currently_pressed.discard(key_name)

        if self.shortcut_keys and self.shortcut_keys.issubset(self.currently_pressed):
            self.toggle_relaying()

    def toggle_relaying(self) -> None:
        """
        Toggle the global relaying state: if it was on, turn it off, otherwise turn it on.
        """
        if self.relaying_active.is_set():
            keyboard = self.gadget_manager.get_keyboard()
            mouse = self.gadget_manager.get_mouse()
            if keyboard:
                keyboard.release_all()
            if mouse:
                mouse.release_all()

            self.currently_pressed.clear()
            self.relaying_active.clear()
            _logger.info("ShortcutToggler: Relaying is now OFF.")
        else:
            self.relaying_active.set()
            _logger.info("ShortcutToggler: Relaying is now ON.")


class RelayController:
    """
    Controls the creation and lifecycle of per-device relays.
    Monitors add/remove events from udev and includes optional auto-discovery.
    """

    def __init__(
        self,
        gadget_manager: GadgetManager,
        device_identifiers: Optional[list[str]] = None,
        auto_discover: bool = False,
        skip_name_prefixes: Optional[list[str]] = None,
        grab_devices: bool = False,
        relaying_active: Optional[asyncio.Event] = None,
        shortcut_toggler: Optional["ShortcutToggler"] = None,
    ) -> None:
        """
        :param gadget_manager: Provides the USB HID gadget devices
        :param device_identifiers: A list of path, MAC, or name fragments to identify devices to relay
        :param auto_discover: If True, relays all valid input devices except those skipped
        :param skip_name_prefixes: A list of device.name prefixes to skip if auto_discover is True
        :param grab_devices: If True, the relay tries to grab exclusive access to each device
        :param relaying_active: asyncio.Event to indicate if relaying is active
        :param shortcut_toggler: ShortcutToggler to allow toggling relaying globally
        """
        self._gadget_manager = gadget_manager
        self._device_ids = [DeviceIdentifier(id) for id in (device_identifiers or [])]
        self._auto_discover = auto_discover
        self._skip_name_prefixes = skip_name_prefixes or ["vc4-hdmi"]
        self._grab_devices = grab_devices
        self._relaying_active = relaying_active
        self._shortcut_toggler = shortcut_toggler

        self._active_tasks: dict[str, Task] = {}
        self._task_group: Optional[TaskGroup] = None
        self._cancelled = False

    async def async_relay_devices(self) -> None:
        """
        Launch a TaskGroup that relays events from all matching devices.
        Dynamically adds or removes tasks when devices appear or disappear.

        :return: Never returns unless an unrecoverable exception or cancellation occurs
        :rtype: None
        """
        try:
            async with TaskGroup() as task_group:
                self._task_group = task_group
                _logger.debug("RelayController: TaskGroup started.")

                for device in await async_list_input_devices():
                    if self._should_relay(device):
                        self.add_device(device.path)

                # Keep running unless canceled
                while not self._cancelled:
                    await asyncio.sleep(0.1)
        except* Exception as exc_grp:
            _logger.exception(
                "RelayController: Exception in TaskGroup", exc_info=exc_grp
            )
        finally:
            self._task_group = None
            _logger.debug("RelayController: TaskGroup exited.")

    def add_device(self, device_path: str) -> None:
        """
        Add a device by path. If a TaskGroup is active, create a new relay task.

        :param device_path: The absolute path to the input device (e.g., /dev/input/event5)
        """
        if not Path(device_path).exists():
            _logger.debug(f"{device_path} does not exist.")
            return

        try:
            device = InputDevice(device_path)
        except (OSError, FileNotFoundError):
            _logger.debug(f"{device_path} vanished before opening.")
            return

        if self._task_group is None:
            _logger.critical(f"No TaskGroup available; ignoring {device}.")
            return

        if device.path in self._active_tasks:
            _logger.debug(f"Device {device} is already active.")
            return

        task = self._task_group.create_task(
            self._async_relay_events(device), name=device.path
        )
        self._active_tasks[device.path] = task
        _logger.debug(f"Created task for {device}.")

    def remove_device(self, device_path: str) -> None:
        """
        Cancel and remove the relay task for a given device path.

        :param device_path: The path of the device to remove
        """
        task = self._active_tasks.pop(device_path, None)
        if task and not task.done():
            task.cancel()
            _logger.debug(f"Cancelled relay for {device_path}.")
        else:
            _logger.debug(f"No active task found for {device_path} to remove.")

    async def _async_relay_events(self, device: InputDevice) -> None:
        """
        Create a DeviceRelay context, then read events in a loop until cancellation or error.

        :param device: The evdev InputDevice to relay
        """
        try:
            async with DeviceRelay(
                device,
                self._gadget_manager,
                grab_device=self._grab_devices,
                relaying_active=self._relaying_active,
                shortcut_toggler=self._shortcut_toggler,
            ) as relay:
                _logger.info(f"Activated {relay}")
                await relay.async_relay_events_loop()
        except (OSError, FileNotFoundError):
            _logger.info(f"Lost connection to {device}.")
        except Exception:
            _logger.exception(f"Unhandled exception in relay for {device}.")
        finally:
            self.remove_device(device.path)

    def _should_relay(self, device: InputDevice) -> bool:
        """
        Decide if a device should be relayed based on auto_discover,
        skip_name_prefixes, or user-specified device_identifiers.

        :param device: The input device to check
        :return: True if we should relay it, False otherwise
        :rtype: bool
        """
        name_lower = device.name.lower()
        if self._auto_discover:
            for prefix in self._skip_name_prefixes:
                if name_lower.startswith(prefix.lower()):
                    return False
            return True

        return any(identifier.matches(device) for identifier in self._device_ids)


class DeviceRelay:
    """
    Relay a single InputDevice's events to USB HID gadgets.

    - Optionally grabs the device exclusively.
    - Retries HID writes if they raise BlockingIOError.
    """

    def __init__(
        self,
        input_device: InputDevice,
        gadget_manager: GadgetManager,
        grab_device: bool = False,
        relaying_active: Optional[asyncio.Event] = None,
        shortcut_toggler: Optional["ShortcutToggler"] = None,
    ) -> None:
        """
        :param input_device: The evdev input device
        :param gadget_manager: Provides references to Keyboard, Mouse, ConsumerControl
        :param grab_device: Whether to grab the device for exclusive access
        :param relaying_active: asyncio.Event that indicates relaying is on/off
        :param shortcut_toggler: Optional handler for toggling relay via a shortcut
        """
        self._input_device = input_device
        self._gadget_manager = gadget_manager
        self._grab_device = grab_device
        self._relaying_active = relaying_active
        self._shortcut_toggler = shortcut_toggler

        self._currently_grabbed = False

    def __str__(self) -> str:
        return f"relay for {self._input_device}"

    @property
    def input_device(self) -> InputDevice:
        """
        The underlying evdev InputDevice being relayed.

        :return: The InputDevice
        :rtype: InputDevice
        """
        return self._input_device

    async def __aenter__(self) -> "DeviceRelay":
        """
        Async context manager entry. Grabs the device if requested.

        :return: self
        """
        if self._grab_device:
            try:
                self._input_device.grab()
                self._currently_grabbed = True
            except Exception as ex:
                _logger.warning(f"Could not grab {self._input_device.path}: {ex}")
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> bool:
        """
        Async context manager exit. Ungrabs the device if we grabbed it.

        :return: False to propagate exceptions
        """
        if self._grab_device:
            try:
                self._input_device.ungrab()
                self._currently_grabbed = False
            except Exception as ex:
                _logger.warning(f"Unable to ungrab {self._input_device.path}: {ex}")
        return False

    async def async_relay_events_loop(self) -> None:
        """
        Continuously read events from the device and relay them
        to the USB HID gadgets. Stops when canceled or on error.

        :return: None
        """
        async for input_event in self._input_device.async_read_loop():
            event = categorize(input_event)

            if any(
                isinstance(event, ev_type)
                for ev_type in [KeyEvent, RelEvent]
                or (
                    isinstance(event, AbsEvent)
                    and event.event.code
                    not in (
                        ecodes.ABS_X,
                        ecodes.ABS_Y,
                        ecodes.ABS_Z,
                        ecodes.ABS_RX,
                        ecodes.ABS_RY,
                    )
                )
            ):
                _logger.debug(
                    f"Received {event} from {self._input_device.name} ({self._input_device.path})"
                )

            if self._shortcut_toggler and isinstance(event, KeyEvent):
                self._shortcut_toggler.handle_key_event(event)

            active = self._relaying_active and self._relaying_active.is_set()

            # Dynamically grab/ungrab if relaying state changes
            if self._grab_device and active and not self._currently_grabbed:
                try:
                    self._input_device.grab()
                    self._currently_grabbed = True
                    _logger.debug(f"Grabbed {self._input_device}")
                except Exception as ex:
                    _logger.warning(f"Could not grab {self._input_device}: {ex}")

            elif self._grab_device and not active and self._currently_grabbed:
                try:
                    self._input_device.ungrab()
                    self._currently_grabbed = False
                    _logger.debug(f"Ungrabbed {self._input_device}")
                except Exception as ex:
                    _logger.warning(f"Could not ungrab {self._input_device}: {ex}")

            if not active:
                continue

            try:
                self.relay_event(event)
            except BlockingIOError:
                _logger.warning("HID write blocked")
            except BrokenPipeError:
                _logger.warning(
                    "BrokenPipeError: USB cable likely disconnected or power-only. "
                    "Pausing relay.\nSee: "
                    "https://github.com/quaxalber/bluetooth_2_usb?tab=readme-ov-file#7-troubleshooting"
                )
                if self._relaying_active:
                    self._relaying_active.clear()
            except Exception:
                _logger.exception(f"Error processing {event}")

    def relay_event(self, event: InputEvent) -> None:
        """
        Relay the given event to the appropriate USB HID device.

        :param event: The evdev InputEvent
        :raises BlockingIOError: If HID device write is blocked
        :raises RuntimeError: If appropriate HID device is not available
        """
        if isinstance(event, RelEvent):
            mouse = self._gadget_manager.get_mouse()
            if mouse is None:
                _logger.warning("Mouse gadget not initialized or manager not enabled.")
                return
            self._move_mouse(event, mouse)

        elif isinstance(event, KeyEvent):
            output_device = self._get_output_device(event)
            if output_device is None:
                _logger.warning(
                    "No appropriate USB gadget found (manager not enabled?)."
                )
                return
            self._send_key_event(event, output_device)

        elif isinstance(event, AbsEvent) and is_gamepad_event(event):
            device = self._gadget_manager.get_gamepad()
            if device is None:
                _logger.warning(
                    "Gamepad gadget not initialized or manager not enabled."
                )
                return
            self._send_abs_event(event, device)

        elif isinstance(event, AbsEvent) and is_digitizer_event(event):
            device = self._gadget_manager.get_digitizer()
            if device is None:
                _logger.warning(
                    "Digitizer gadget not initialized or manager not enabled."
                )
                return
            self._send_abs_event(event, device)

    def _move_mouse(self, event: RelEvent, mouse: Mouse) -> None:
        """
        Relay relative mouse movement events to the USB HID Mouse gadget.

        :param event: A RelEvent describing the movement
        :param mouse: Mouse HID device
        """
        x, y, mwheel = get_mouse_movement(event)
        mouse.move(x, y, mwheel)

    def _send_abs_event(
        self, event: AbsEvent, device: Union[Gamepad, Digitizer]
    ) -> None:
        """
        Relay absolute axis events to gamepad or digitizer.

        :param event: The AbsEvent to process
        :param device: The HID device (Gamepad or Digitizer) to send the event to
        """
        abs_info = self._input_device.absinfo(event.event.code)
        if abs_info is None:
            _logger.warning(f"No AbsInfo available for axis {event.event.code}")
            return

        scaled_value = scale_axis_value(event, abs_info)
        if scaled_value is None:
            return

        if isinstance(device, Gamepad):
            mapping = GAMEPAD_AXIS_MAP.get(event.event.code)
            if mapping:
                axis_name, _, _ = mapping
                if axis_name.startswith("hat"):
                    hat_id, coord = axis_name.split("_", 1)
                    device.set_hat(hat_id=hat_id, **{coord: scaled_value})  # type: ignore
                else:
                    device.move_axes(**{axis_name: scaled_value})  # type: ignore
        elif isinstance(device, Digitizer):
            mapping = DIGITIZER_AXIS_MAP.get(event.event.code)
            if mapping:
                axis_name, _, _ = mapping
                device.update(**{axis_name: scaled_value})  # type: ignore

    def _send_key_event(
        self,
        event: KeyEvent,
        output_device: Union[ConsumerControl, Keyboard, Mouse, Gamepad, Digitizer],
    ) -> None:
        """
        Relay a key event (press/release) to the appropriate HID gadget.

        :param event: The KeyEvent to process
        :param output_device: The HID device to send the event to
        """
        key_id, key_name = evdev_to_usb_hid(event)
        if key_id is None or key_name is None:
            return

        if event.keystate == KeyEvent.key_down:
            _logger.debug(f"Pressing {key_name} (0x{key_id:02X}) via {output_device}")
            output_device.press(key_id)
        elif event.keystate == KeyEvent.key_up:
            _logger.debug(f"Releasing {key_name} (0x{key_id:02X}) via {output_device}")
            output_device.release(key_id)

    def _get_output_device(
        self, event: KeyEvent
    ) -> Union[ConsumerControl, Keyboard, Mouse, Gamepad, Digitizer, None]:
        """
        Determine which HID gadget to target for the given key event.

        :param event: The KeyEvent to process
        :return: An appropriate HID device object, or None if not found
        """
        if is_mouse_button(event):
            return self._gadget_manager.get_mouse()
        elif is_digitizer_button(event):
            return self._gadget_manager.get_digitizer()
        elif is_keyboard_key(event):
            return self._gadget_manager.get_keyboard()
        elif is_consumer_key(event):
            return self._gadget_manager.get_consumer()
        elif is_gamepad_button(event):
            return self._gadget_manager.get_gamepad()
        return None


class DeviceIdentifier:
    """
    Identifies an input device by path (/dev/input/eventX), MAC address,
    or a substring of the device name.
    """

    def __init__(self, device_identifier: str) -> None:
        """
        :param device_identifier: Path, MAC, or name fragment
        """
        self._value = device_identifier
        self._type = self._determine_identifier_type()
        self._normalized_value = self._normalize_identifier()

    def __str__(self) -> str:
        return f'{self._type} "{self._value}"'

    def _determine_identifier_type(self) -> str:
        if re.match(r"^/dev/input/event.*$", self._value):
            return "path"
        if re.match(r"^([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})$", self._value):
            return "mac"
        return "name"

    def _normalize_identifier(self) -> str:
        if self._type == "path":
            return self._value
        if self._type == "mac":
            return self._value.lower().replace("-", ":")
        return self._value.lower()

    def matches(self, device: InputDevice) -> bool:
        """
        Check whether this identifier matches the given evdev InputDevice.

        :param device: An evdev InputDevice to compare
        :return: True if matched, False otherwise
        :rtype: bool
        """
        if self._type == "path":
            return self._value == device.path
        if self._type == "mac":
            return self._normalized_value == (device.uniq or "").lower()
        return self._normalized_value in device.name.lower()


async def async_list_input_devices() -> list[InputDevice]:
    """
    Return a list of available /dev/input/event* devices.

    :return: List of InputDevice objects
    :rtype: list[InputDevice]
    """
    try:
        return [InputDevice(path) for path in list_devices()]
    except (OSError, FileNotFoundError) as ex:
        _logger.critical(f"Failed listing devices: {ex}")
        return []
    except Exception:
        _logger.exception("Unexpected error listing devices")
        return []


class UdcStateMonitor:
    """
    Monitors the UDC (USB Device Controller) state and
    sets/clears an Event when the device is configured or not.
    """

    def __init__(
        self,
        relaying_active: asyncio.Event,
        udc_path: Path = Path("/sys/class/udc/20980000.usb/state"),
        poll_interval: float = 0.5,
    ) -> None:
        """
        :param relaying_active: Event controlling whether relaying is active
        :param udc_path: Path to the UDC state file
        :param poll_interval: Interval (seconds) to re-check the UDC state
        """
        self._relaying_active = relaying_active
        self.udc_path = udc_path
        self.poll_interval = poll_interval

        self._stop = False
        self._task: Optional[asyncio.Task] = None
        self._last_state: Optional[str] = None

        if not self.udc_path.is_file():
            _logger.warning(
                f"UDC state file {self.udc_path} not found. Cable monitoring may be unavailable."
            )

    async def __aenter__(self):
        """
        Async context manager entry. Starts a background task to poll the UDC state.
        """
        self._stop = False
        self._task = asyncio.create_task(self._poll_state())
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """
        Async context manager exit. Cancels the polling task.
        """
        if self._task:
            self._stop = True
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
        return False

    async def _poll_state(self):
        while not self._stop:
            new_state = self._read_udc_state()
            if new_state != self._last_state:
                self._handle_state_change(new_state)
                self._last_state = new_state
            await asyncio.sleep(self.poll_interval)

    def _read_udc_state(self) -> str:
        """
        Read the UDC state file. If not found, treat as "not_attached".

        :return: The current UDC state (e.g. "configured")
        :rtype: str
        """
        try:
            with open(self.udc_path, "r") as f:
                return f.read().strip()
        except FileNotFoundError:
            return "not_attached"

    def _handle_state_change(self, new_state: str):
        """
        Handle a change in the UDC state. If "configured", set relaying_active.
        Otherwise clear it.

        :param new_state: The new UDC state
        """
        _logger.debug(f"UDC state changed to '{new_state}'")

        if new_state == "configured":
            self._relaying_active.set()
        else:
            self._relaying_active.clear()


class UdevEventMonitor:
    """
    Monitors udev for /dev/input/event* add/remove events and
    notifies the RelayController.
    """

    def __init__(self, relay_controller: RelayController) -> None:
        """
        :param relay_controller: The RelayController to add/remove devices
        :param loop: The asyncio event loop
        """
        self.relay_controller = relay_controller

        self.context = pyudev.Context()
        self.monitor = pyudev.Monitor.from_netlink(self.context)
        self.monitor.filter_by("input")
        self.observer = pyudev.MonitorObserver(self.monitor, self._udev_event_callback)

    async def __aenter__(self):
        """
        Async context manager entry. Starts the pyudev monitor observer.
        """
        self.observer.start()
        _logger.debug("UdevEventMonitor started observer.")
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """
        Async context manager exit. Stops the pyudev monitor observer.
        """
        self.observer.stop()
        _logger.debug("UdevEventMonitor stopped observer.")
        return False

    def _udev_event_callback(self, action: str, device: pyudev.Device) -> None:
        """
        pyudev callback for input devices.

        :param action: "add" or "remove"
        :param device: The pyudev device
        """
        device_node = device.device_node
        if not device_node or not device_node.startswith("/dev/input/event"):
            return

        if action == "add":
            _logger.debug(f"UdevEventMonitor: Added input => {device_node}")
            self.relay_controller.add_device(device_node)
        elif action == "remove":
            _logger.debug(f"UdevEventMonitor: Removed input => {device_node}")
            self.relay_controller.remove_device(device_node)
