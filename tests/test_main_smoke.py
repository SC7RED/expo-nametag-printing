"""Smoke tests for src/main.py and src/config.py.

src/main.py runs at module level (no main()), so every test runs the whole
script with runpy against fake versions of its third-party modules:

  FreeSimpleGUI    fake elements and a Window whose read() replays a script
  win32com.client  fake Dispatch returning recording DYMO objects
  requests         fake post() answering like the Swapcard GraphQL API
  dotenv           load_dotenv() that only records its arguments

The real src/config.py and src/query.py run. time.time() is replaced by a
fake clock so the 3-second scanner debounce is deterministic and instant.
No window opens, nothing touches the network or a printer, and no packages
are needed:

    python -m unittest discover -s tests -v
"""

import contextlib
import copy
import importlib
import io
import os
import runpy
import sys
import tempfile
import time
import traceback
import types
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO_ROOT, "src")
MAIN_PATH = os.path.join(SRC_DIR, "main.py")
LABEL_FILE = os.path.join(SRC_DIR, "label", "student_badge_v3.label")

# Fake settings (not real values)
EVENT_ID = "RXZlbnRfOTk5OTk5"
PROXY_URL = "https://expo-nametag.test.workers.dev"
API_KEY = "test-laptop-token-not-real"
MAJOR_ID = "RmllbGREZWZpbml0aW9uX01ham9y"
YEAR_ID = "RmllbGREZWZpbml0aW9uX1llYXI="
ENV_KEYS = ("PROXY_URL", "PROXY_TOKEN", "SWAPCARD_MAJOR_ID", "SWAPCARD_YEAR_ID")
DEFAULT_ENV = {
    "PROXY_URL": PROXY_URL,
    "PROXY_TOKEN": API_KEY,
    "SWAPCARD_MAJOR_ID": MAJOR_ID,
    "SWAPCARD_YEAR_ID": YEAR_ID,
}
SCREEN_SIZE = (1920, 1080)
PRINTER_NAME = "DYMO LabelWriter 450 Turbo"
WINDOW_TITLE = "2026 Engineering Expo Student Nametag Printing"

MAJORS = [
    "Aerospace Engineering",
    "Biological Systems Engineering",
    "Biomedical Engineering",
    "Building Construction",
    "Chemical Engineering",
    "Civil Engineering",
    "Computer Engineering",
    "Computer Science",
    "Construction Engineering (CEM)",
    "Electrical Engineering",
    "Engineering Science and Mechanics",
    "General Engineering",
    "Industrial and Systems Engineering",
    "Materials Science Engineering",
    "Mechanical Engineering",
    "Mining Engineering",
    "Ocean Engineering",
    "Non-Engineering",
]
YEARS = ["Freshman", "Sophomore", "Junior", "Senior", "Masters", "Doctorate"]

_MISSING = object()
FAKE_MODULE_NAMES = (
    "FreeSimpleGUI", "win32com", "win32com.client", "requests", "requests.exceptions", "dotenv",
)
APP_MODULE_NAMES = ("config", "query")


# ---------------------------------------------------------------------------
# Fake requests exceptions (module level so tests can build instances)
# ---------------------------------------------------------------------------

class FakeRequestException(IOError):
    pass


class FakeHTTPError(FakeRequestException):
    pass


class FakeConnectionError(FakeRequestException):
    pass


class FakeTimeout(FakeRequestException):
    pass


class FakeConnectTimeout(FakeConnectionError, FakeTimeout):
    pass


class FakeReadTimeout(FakeTimeout):
    pass


class FakeJSONDecodeError(ValueError):
    pass


class ScriptExhausted(Exception):
    """window.read() kept being called after the scripted events ran out."""


NOT_JSON = object()


class FakeResponse:
    def __init__(self, status_code=200, payload=None, text=None):
        self.status_code = status_code
        self._payload = payload
        self.text = text if text is not None else ("<html>error</html>" if payload is NOT_JSON else repr(payload))

    def json(self):
        if self._payload is NOT_JSON:
            raise FakeJSONDecodeError("Expecting value: line 1 column 1 (char 0)")
        return copy.deepcopy(self._payload)


class FakeClock:
    def __init__(self, start=1_000_000.0):
        self.now = start

    def time(self):
        return self.now


class FakeElement:
    def __init__(self, kind, args, kwargs):
        self.kind = kind
        self.args = args
        self.kwargs = kwargs

    def describe(self):
        return (self.kind, self.args, tuple(sorted(self.kwargs.items())))

    def __repr__(self):
        return "FakeElement%r" % (self.describe(),)


def describe_layout(layout):
    return [[element.describe() for element in row] for row in layout]


# ---------------------------------------------------------------------------
# Script and Swapcard data builders
# ---------------------------------------------------------------------------

def submit(dt=10.0, event="Submit", **values):
    """A window.read() result. dt = seconds on the fake clock since the last read."""
    full = {
        "BRID": "", "PID": "", "manual_input": False,
        "FN": "", "LN": "", "MJ": MAJORS[0], "YR": "Freshman", "RID": "",
    }
    full.update(values)
    return (event, full, dt)


def manual(fn, ln, major, year, rid, dt=10.0):
    return submit(dt=dt, manual_input=True, FN=fn, LN=ln, MJ=major, YR=year, RID=rid)


def close(dt=10.0, event=None):
    """sg.WIN_CLOSED (None) by default; event='Exit' for the Exit event."""
    return (event, None, dt)


def make_person(first="Jane", last="Doe", major="Mechanical Engineering", year="Junior",
                barcode="SWC-7Q2M9XP", email="jdoe1@vt.edu", phones=("+1 540-555-0101",),
                badges=_MISSING, fields=_MISSING):
    """An eventPerson node shaped like QueryConfig.people_filter_query asks for."""
    if fields is _MISSING:
        fields = [
            {"value": "Blacksburg, VA",
             "definition": {"id": "RmllbGREZWZpbml0aW9uX0hvbWV0b3du", "translations": [{"name": "Hometown"}]}},
            {"translations": [{"value": major}],
             "definition": {"id": MAJOR_ID, "translations": [{"name": "Major"}]}},
            {"translations": [{"value": year}],
             "definition": {"id": YEAR_ID, "translations": [{"name": "School Year"}]}},
            {"studentID": 906000001,
             "definition": {"id": "RmllbGREZWZpbml0aW9uX1N0dWRlbnRJRA==", "translations": [{"name": "Student ID"}]}},
            {},  # a field type that none of the query's fragments match comes back empty
        ]
    if badges is _MISSING:
        badges = [{"barcode": barcode}]
    return {
        "id": "RXZlbnRQZXJzb25fMTIzNDU=", "userId": "VXNlcl8xMjM0NQ==", "email": email,
        "firstName": first, "lastName": last,
        "phoneNumbers": [{"number": p} for p in phones],
        "jobTitle": None, "photoUrl": None, "organization": "Virginia Tech", "websiteUrl": None,
        "biography": None, "groups": [{"name": "Students"}],
        "withEvent": {"fields": fields, "badges": badges},
        "isVisible": True, "source": "REGISTRATION", "createdAt": "2026-09-30T14:00:00Z",
        "updatedAt": "2026-10-01T09:00:00Z", "type": "USER", "engagementScore": 0,
    }


def people_payload(nodes):
    return {"data": {"eventPerson": {"nodes": nodes}}}


EVENT_PAYLOAD = {"data": {"event": {
    "id": EVENT_ID, "slug": "engineering-expo-2026", "title": "Engineering Expo 2026",
    "beginsAt": "2026-10-28T13:00:00Z", "endsAt": "2026-10-28T21:00:00Z", "isLive": True,
}}}


def nametag_block(fn, ln, major, year, rid):
    """What main.py prints for one student (including print()'s newline)."""
    return ("#" * 10 + " NameTag Info " + "#" * 10 +
            f"\n{'First Name:':<20}{fn}" + f"\n{'Last Name:':<20}{ln}" +
            f"\n{'Major:':<20}{major}" + f"\n{'Year:':<20}{year}" +
            f"\n{'Registration ID:':<20}{rid}\n" + "\n")


def setfield_calls(fn, ln, major, year, rid):
    return [("fn", fn), ("ln", ln), ("y", year), ("m", major), ("BARCODE", rid)]


def norm(path):
    return os.path.normcase(os.path.abspath(os.fspath(path)))


# ---------------------------------------------------------------------------
# The harness
# ---------------------------------------------------------------------------

class AppRun:
    """One run of src/main.py (or an import of src/config.py) against fakes.

    people          {("qrCodes"|"emails", value): [nodes]} for the default Swapcard fake
    event_response  None (default) | FakeResponse | exception instance | callable(call)
    people_response None (default) | FakeResponse | exception instance | callable(call)
    printers        what GetDymoPrinters() returns
    open_result     what Open() returns, or an exception instance to raise
    dispatch_error  exception instance to raise from Dispatch()
    setfield_error / print_error   exception instance to raise from SetField / Print
    end_print_error exception instance EndPrintJob raises, on the 1-based calls in
                    end_print_fail_on (None = every call)
    """

    def __init__(self, script=(), *, people=None, event_response=None, people_response=None,
                 printers=PRINTER_NAME, open_result=True, dispatch_error=None,
                 setfield_error=None, print_error=None, end_print_error=None,
                 end_print_fail_on=None, after_close_dt=0.5, extra_read_limit=50,
                 dotenv_values=None):
        self.script = list(script)
        self.dotenv_values = dotenv_values or {}
        self.people = people or {}
        self.event_response = event_response
        self.people_response = people_response
        self.printers = printers
        self.open_result = open_result
        self.dispatch_error = dispatch_error
        self.setfield_error = setfield_error
        self.print_error = print_error
        self.end_print_error = end_print_error
        self.end_print_fail_on = end_print_fail_on
        self.after_close_dt = after_close_dt
        self.extra_read_limit = extra_read_limit

        self.clock = FakeClock()
        self.sg_calls = []        # theme / set_options
        self.dispatched = []      # ProgIDs passed to Dispatch
        self.dymo_calls = []      # (method, args) on the DymoAddIn object
        self.open_paths = []      # Open() args resolved against the CWD at call time
        self.set_fields = []      # (name, value) on the DymoLabels object
        self.posts = []           # requests.post calls
        self.dotenv_calls = []    # load_dotenv args
        self.window = None
        self.window_title = None
        self.window_layout = None
        self.window_kwargs = None
        self.reads = 0
        self.extra_reads = 0
        self.closed = False
        self._pos = 0
        self._end_print_count = 0

        self.stdout = ""
        self.error = None
        self.tb = ""
        self.globals = None
        self.module = None

    # --- views -------------------------------------------------------------

    def method_calls(self, name):
        return [args for method, args in self.dymo_calls if method == name]

    def people_posts(self):
        return [p for p in self.posts if p["kind"] == "people"]

    def layout(self):
        return describe_layout(self.window_layout) if self.window_layout is not None else None

    # --- fake FreeSimpleGUI ------------------------------------------------

    def _read(self):
        if self.closed:
            raise RuntimeError("window.read() after window.close()")
        if self._pos < len(self.script):
            event, values, dt = self.script[self._pos]
            self._pos += 1
            self.reads += 1
            self.clock.now += dt
            return event, copy.deepcopy(values)
        # A closed FreeSimpleGUI (PySimpleGUI 4.x) window keeps returning (WIN_CLOSED, None)
        self.extra_reads += 1
        if self.extra_reads > self.extra_read_limit:
            raise ScriptExhausted("window.read() called %d times after the script ended" % self.extra_reads)
        self.clock.now += self.after_close_dt
        return None, None

    def _make_sg(self):
        run = self
        sg = types.ModuleType("FreeSimpleGUI")
        sg.WIN_CLOSED = None
        sg.WINDOW_CLOSED = None

        def theme(new_theme=None):
            run.sg_calls.append(("theme", (new_theme,), {}))
            return new_theme

        def set_options(**kwargs):
            run.sg_calls.append(("set_options", (), kwargs))

        sg.theme = theme
        sg.set_options = set_options

        def element(kind):
            def factory(*args, **kwargs):
                return FakeElement(kind, args, kwargs)
            factory.__name__ = kind
            return factory

        for kind in ("Text", "T", "InputText", "Input", "Checkbox", "Combo", "Submit", "Button",
                     "Exit", "OK", "Cancel"):
            setattr(sg, kind, element(kind))

        class Window:
            def __init__(self, title, layout=None, **kwargs):
                run.window = self
                run.window_title = title
                run.window_layout = layout
                run.window_kwargs = kwargs

            @staticmethod
            def get_screen_size():
                return SCREEN_SIZE

            def read(self, *args, **kwargs):
                return run._read()

            def close(self):
                run.closed = True

        sg.Window = Window
        return sg

    # --- fake win32com -----------------------------------------------------

    def _make_win32com(self):
        run = self

        class DymoAddIn:
            def _log(self, method, *args):
                run.dymo_calls.append((method, args))

            def GetDymoPrinters(self):
                self._log("GetDymoPrinters")
                return run.printers

            def SelectPrinter(self, name):
                self._log("SelectPrinter", name)
                return True

            def Open(self, path):
                self._log("Open", path)
                run.open_paths.append(norm(path))
                if isinstance(run.open_result, BaseException):
                    raise run.open_result
                return run.open_result

            def StartPrintJob(self):
                self._log("StartPrintJob")

            def Print(self, copies, show_dialog):
                self._log("Print", copies, show_dialog)
                if run.print_error is not None:
                    raise run.print_error
                return True

            def EndPrintJob(self):
                self._log("EndPrintJob")
                run._end_print_count += 1
                if run.end_print_error is not None and (
                        run.end_print_fail_on is None or run._end_print_count in run.end_print_fail_on):
                    raise run.end_print_error

        class DymoLabels:
            def SetField(self, name, value):
                run.set_fields.append((name, value))
                run.dymo_calls.append(("SetField", (name, value)))  # to check order against Open
                if run.setfield_error is not None:
                    raise run.setfield_error
                return True

        def Dispatch(progid, *args, **kwargs):
            run.dispatched.append(progid)
            if run.dispatch_error is not None:
                raise run.dispatch_error
            if progid == "Dymo.DymoAddIn":
                return DymoAddIn()
            if progid == "Dymo.DymoLabels":
                return DymoLabels()
            raise OSError("Invalid class string: " + progid)

        win32com = types.ModuleType("win32com")
        client = types.ModuleType("win32com.client")
        client.Dispatch = Dispatch
        win32com.client = client
        return win32com, client

    # --- fake requests -----------------------------------------------------

    def _make_requests(self):
        run = self
        requests = types.ModuleType("requests")
        exceptions = types.ModuleType("requests.exceptions")
        for name, cls in (("RequestException", FakeRequestException), ("HTTPError", FakeHTTPError),
                          ("ConnectionError", FakeConnectionError), ("Timeout", FakeTimeout),
                          ("ConnectTimeout", FakeConnectTimeout), ("ReadTimeout", FakeReadTimeout),
                          ("JSONDecodeError", FakeJSONDecodeError)):
            setattr(requests, name, cls)
            setattr(exceptions, name, cls)
        requests.exceptions = exceptions

        def post(url=None, data=None, json=None, **kwargs):
            lookup = (json or {}).get("lookup")
            kind = {"event": "event", "person": "people"}.get(lookup, "other")
            call = {
                "kind": kind, "url": url, "headers": copy.deepcopy(kwargs.get("headers")),
                "body": copy.deepcopy(json),
                "timeout": kwargs.get("timeout"),
            }
            run.posts.append(call)
            override = run.event_response if kind == "event" else run.people_response
            if override is not None:
                if isinstance(override, BaseException):
                    raise override
                if callable(override):
                    return override(call)
                return override
            return run._default_post(call)

        requests.post = post
        return requests, exceptions

    def _default_post(self, call):
        if not (call["headers"] or {}).get("Authorization"):
            return FakeResponse(401, {"errors": [{"message": "Unauthorized"}]},
                                text='{"errors":[{"message":"Unauthorized"}]}')
        if call["kind"] == "event":
            return FakeResponse(200, EVENT_PAYLOAD)
        if call["kind"] == "people":
            (key, value), = call["body"]["filters"].items()
            return FakeResponse(200, people_payload(copy.deepcopy(self.people.get((key, value), []))))
        return FakeResponse(400, {"errors": [{"message": "unknown query"}]})

    # --- fake dotenv -------------------------------------------------------

    def _make_dotenv(self):
        run = self
        dotenv = types.ModuleType("dotenv")

        def load_dotenv(*args, **kwargs):
            # like python-dotenv with override=False: the .env never replaces a set variable
            run.dotenv_calls.append((args, kwargs))
            for key, value in run.dotenv_values.items():
                os.environ.setdefault(key, value)
            return bool(run.dotenv_values)

        dotenv.load_dotenv = load_dotenv
        return dotenv

    # --- running -----------------------------------------------------------

    def run(self, *, target="main", main_path=MAIN_PATH, src_dir=SRC_DIR, cwd=None,
            env=None, frozen=None):
        """target='main' runs main_path; target='config' imports src_dir/config.py.

        frozen: None, or {"executable": ..., "meipass": ... (optional)} to fake PyInstaller.
        """
        env = DEFAULT_ENV if env is None else env
        win32com, win32com_client = self._make_win32com()
        requests, requests_exceptions = self._make_requests()
        fakes = {
            "FreeSimpleGUI": self._make_sg(),
            "win32com": win32com,
            "win32com.client": win32com_client,
            "requests": requests,
            "requests.exceptions": requests_exceptions,
            "dotenv": self._make_dotenv(),
        }

        saved_modules = {n: sys.modules.get(n, _MISSING) for n in FAKE_MODULE_NAMES + APP_MODULE_NAMES}
        saved_path = list(sys.path)
        saved_cwd = os.getcwd()
        saved_bytecode = sys.dont_write_bytecode
        out = io.StringIO()
        try:
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.dict(os.environ))
                for key in ENV_KEYS:
                    os.environ.pop(key, None)
                os.environ.update(env)
                if frozen is not None:
                    stack.enter_context(mock.patch.object(sys, "frozen", True, create=True))
                    stack.enter_context(mock.patch.object(sys, "executable", frozen["executable"]))
                    if "meipass" in frozen:
                        stack.enter_context(mock.patch.object(sys, "_MEIPASS", frozen["meipass"], create=True))
                    elif hasattr(sys, "_MEIPASS"):
                        stack.enter_context(mock.patch.object(sys, "_MEIPASS", None))
                        delattr(sys, "_MEIPASS")
                stack.enter_context(mock.patch.object(time, "time", self.clock.time))
                for name in APP_MODULE_NAMES:
                    sys.modules.pop(name, None)
                sys.modules.update(fakes)
                sys.path.insert(0, src_dir)
                sys.dont_write_bytecode = True  # keep src/ free of __pycache__
                if cwd is not None:
                    os.chdir(cwd)
                with contextlib.redirect_stdout(out):
                    try:
                        if target == "main":
                            self.globals = runpy.run_path(main_path, run_name="__main__")
                        else:
                            self.module = importlib.import_module("config")
                    except Exception as err:  # recorded for the test to assert on
                        self.error = err
                        self.tb = traceback.format_exc()
        finally:
            os.chdir(saved_cwd)
            sys.dont_write_bytecode = saved_bytecode
            sys.path[:] = saved_path
            for name, module in saved_modules.items():
                if module is _MISSING:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = module
        self.stdout = out.getvalue()
        return self


def run_app(script, **kwargs):
    run_kwargs = {k: kwargs.pop(k) for k in ("target", "main_path", "src_dir", "cwd", "env", "frozen")
                  if k in kwargs}
    return AppRun(script, **kwargs).run(**run_kwargs)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class AppTestCase(unittest.TestCase):
    maxDiff = None

    def assertCleanRun(self, run, reads=None):
        """No uncaught exception, window built, closed once, no reads past the close."""
        self.assertIsNone(run.error, "main.py raised:\n" + run.tb + "\nstdout:\n" + run.stdout)
        self.assertIsNotNone(run.window, "window was never created")
        self.assertTrue(run.closed, "window.close() was not called")
        self.assertEqual(run.extra_reads, 0, "window.read() was called after the close event")
        if reads is not None:
            self.assertEqual(run.reads, reads)

    def assertPrintedOnce(self, run, fn, ln, major, year, rid):
        self.assertEqual(run.set_fields, setfield_calls(fn, ln, major, year, rid))
        self.assertEqual(len(run.method_calls("StartPrintJob")), 1)
        self.assertEqual(run.method_calls("Print"), [(1, False)])
        # once for the job, once more when the window closes
        self.assertEqual(len(run.method_calls("EndPrintJob")), 2)
        self.assertIn(nametag_block(fn, ln, major, year, rid), run.stdout)
        self.assertIn("\nPrint Success\n", run.stdout)


class WindowLayoutTests(AppTestCase):
    """The UI must not change."""

    def test_window_title_size_theme_and_layout(self):
        run = run_app([close()])
        self.assertCleanRun(run, reads=1)
        self.assertEqual(run.sg_calls, [("theme", ("SystemDefaultForReal",), {}),
                                        ("set_options", (), {"font": ("Calibri", 22)})])
        self.assertEqual(run.window_title, WINDOW_TITLE)
        self.assertEqual(run.window_kwargs, {"size": SCREEN_SIZE})

        def label(text):
            return ("Text", (), (("font", ("Courier", 20)), ("size", (15, 1)), ("text", text)))

        def entry(key, **extra):
            return ("InputText", (), tuple(sorted(dict(do_not_clear=False, key=key, **extra).items())))

        expected = [
            [("Text", ("Option 1 - Scan Swapcard Badge Code or the Code from their Confirmation Email",), ())],
            [label("Badge Code"), entry("BRID")],
            [("Text", ("Option 2 - Input VT PID",), ())],
            [label("VT PID"), entry("PID")],
            [("Checkbox", ("Manual Input Backup (enable by checkbox)",), (("key", "manual_input"),))],
            [label("First Name"), entry("FN")],
            [label("Last Name"), entry("LN")],
            [label("Major"), ("Combo", (MAJORS,), (("default_value", "Aerospace Engineering"), ("key", "MJ")))],
            [label("Year"), ("Combo", (YEARS,), (("default_value", "Freshman"), ("key", "YR")))],
            [label("Registration ID"), entry("RID", default_text="")],
            [("Submit", (), ()),
             ("Text", ("Please only exit this program by closing the window.",), (("text_color", "red"),))],
        ]
        self.assertEqual(run.layout(), expected)

    def test_startup_output(self):
        run = run_app([close()])
        self.assertCleanRun(run)
        self.assertEqual(run.stdout, "".join([
            repr(EVENT_PAYLOAD) + "\n",
            "Before Dispatch\n", "After Dispatch\n",
            PRINTER_NAME + "\n", "Selected:" + PRINTER_NAME + "\n",
            "Window Size: (1920, 1080)\n",
        ]))
        self.assertEqual(run.dispatched, ["Dymo.DymoAddIn", "Dymo.DymoLabels"])
        self.assertEqual(run.method_calls("SelectPrinter"), [(PRINTER_NAME,)])
        # the event check is the only request at startup
        self.assertEqual([p["kind"] for p in run.posts], ["event"])
        self.assertEqual(run.posts[0]["body"], {"lookup": "event"})


class SwapcardSuccessTests(AppTestCase):

    def test_lookup_by_badge_code(self):
        person = make_person()
        run = run_app([submit(BRID="SWC-7Q2M9XP"), close()],
                      people={("qrCodes", "SWC-7Q2M9XP"): [person]})
        self.assertCleanRun(run, reads=2)
        self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", "SWC-7Q2M9XP")
        self.assertEqual(run.dymo_calls[-4:], [("StartPrintJob", ()), ("Print", (1, False)),
                                               ("EndPrintJob", ()), ("EndPrintJob", ())])
        lookup, = run.people_posts()
        self.assertEqual(lookup["url"], PROXY_URL)
        self.assertEqual(lookup["headers"], {"Authorization": API_KEY, "Accept": "application/json"})
        self.assertEqual(lookup["body"], {"lookup": "person", "filters": {"qrCodes": "SWC-7Q2M9XP"}})
        self.assertEqual(lookup["timeout"], 5)
        self.assertIn(repr(people_payload([person])) + "\n", run.stdout)
        self.assertIn("#" * 10 + " Query Logged " + "#" * 10 + "\n\n", run.stdout)
        self.assertNotIn("Warning", run.stdout)

    def test_lookup_by_pid_without_domain(self):
        run = run_app([submit(PID="jdoe1"), close()],
                      people={("emails", "jdoe1@vt.edu"): [make_person()]})
        self.assertCleanRun(run, reads=2)
        self.assertEqual(run.people_posts()[0]["body"]["filters"], {"emails": "jdoe1@vt.edu"})
        self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", "SWC-7Q2M9XP")

    def test_lookup_by_pid_with_domain(self):
        for email in ("jdoe1@vt.edu", "jane.doe@gmail.com"):
            with self.subTest(email=email):
                run = run_app([submit(PID=email), close()],
                              people={("emails", email): [make_person(email=email)]})
                self.assertCleanRun(run, reads=2)
                self.assertEqual(run.people_posts()[0]["body"]["filters"], {"emails": email})
                self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", "SWC-7Q2M9XP")

    def test_badge_code_wins_over_pid(self):
        run = run_app([submit(BRID="SWC-7Q2M9XP", PID="someone"), close()],
                      people={("qrCodes", "SWC-7Q2M9XP"): [make_person()]})
        self.assertCleanRun(run)
        self.assertEqual([p["body"]["filters"] for p in run.people_posts()], [{"qrCodes": "SWC-7Q2M9XP"}])

    def test_person_without_phone_number(self):
        run = run_app([submit(BRID="SWC-1"), close()],
                      people={("qrCodes", "SWC-1"): [make_person(barcode="SWC-1", phones=())]})
        self.assertCleanRun(run)
        self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", "SWC-1")

    def test_freshman_without_a_major_still_prints(self):
        # Freshmen always print as General Engineering, so a missing major doesn't matter
        run = run_app([submit(BRID="SWC-1"), close()],
                      people={("qrCodes", "SWC-1"): [make_person(barcode="SWC-1", major=None, year="Freshman")]})
        self.assertCleanRun(run)
        self.assertPrintedOnce(run, "Jane", "Doe", "General Engineering", "Freshman", "SWC-1")

    def test_major_special_cases_from_swapcard(self):
        # (year, Swapcard major, major printed on the badge)
        cases = [
            ("Freshman", "Mechanical Engineering", "General Engineering"),
            ("Freshman", "Computer Science", "General Engineering"),
            ("First Year (Freshman)", "Aerospace Engineering", "General Engineering"),
            ("Junior", "Construction Engineering and Management", "Construction Engineering (CEM)"),
            ("Senior", "Computer Science (CS)", "Computer Science"),
            ("Senior", "computer science", "Computer Science"),
            ("Sophomore", "Building Construction (BC)", "Building Construction"),
            ("Sophomore", "Building Construction", "Building Construction"),
            ("Junior", "Computer Engineering", "Computer Engineering"),
            ("Masters", "Materials Science Engineering", "Materials Science Engineering"),
        ]
        people, script = {}, []
        for i, (year, major, _) in enumerate(cases):
            code = "SWC-%04d" % i
            people[("qrCodes", code)] = [make_person(first="S%d" % i, major=major, year=year, barcode=code)]
            script.append(submit(BRID=code))
        script.append(close())
        run = run_app(script, people=people)
        self.assertCleanRun(run, reads=len(cases) + 1)
        expected = []
        for i, (year, _, printed_major) in enumerate(cases):
            expected += setfield_calls("S%d" % i, "Doe", printed_major, year, "SWC-%04d" % i)
            self.assertIn(nametag_block("S%d" % i, "Doe", printed_major, year, "SWC-%04d" % i), run.stdout)
        self.assertEqual(run.set_fields, expected)
        self.assertEqual(len(run.method_calls("Print")), len(cases))


class ManualInputTests(AppTestCase):

    def test_manual_input(self):
        run = run_app([manual("Sam", "Hokie", "Civil Engineering", "Senior", "RID-42"), close()])
        self.assertCleanRun(run, reads=2)
        self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Senior", "RID-42")
        self.assertEqual(run.people_posts(), [], "manual mode must not call Swapcard")

    def test_manual_input_ignores_badge_and_pid_fields(self):
        script = [submit(manual_input=True, BRID="SWC-1", PID="jdoe1", FN="Sam", LN="Hokie",
                         MJ="Civil Engineering", YR="Junior", RID="RID-1"), close()]
        run = run_app(script)
        self.assertCleanRun(run)
        self.assertEqual(run.people_posts(), [])
        self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Junior", "RID-1")

    def test_manual_special_cases(self):
        cases = [
            ("Freshman", "Mechanical Engineering", "General Engineering"),
            ("Freshman", "Aerospace Engineering", "General Engineering"),  # the window's defaults
            ("Junior", "Construction Engineering and Management", "Construction Engineering (CEM)"),
            ("Senior", "Computer Science", "Computer Science"),
            ("Sophomore", "Building Construction", "Building Construction"),
            ("Doctorate", "Ocean Engineering", "Ocean Engineering"),
        ]
        script = [manual("M%d" % i, "L", major, year, "R%d" % i) for i, (year, major, _) in enumerate(cases)]
        run = run_app(script + [close()])
        self.assertCleanRun(run)
        expected = []
        for i, (year, _, printed) in enumerate(cases):
            expected += setfield_calls("M%d" % i, "L", printed, year, "R%d" % i)
        self.assertEqual(run.set_fields, expected)

    def test_each_badge_reopens_the_label_first(self):
        # Once a DYMO field has been set to empty text it prints in a small default font until
        # the label is reopened, so a blank badge must not change how the next one looks.
        run = run_app([manual("", "", "Civil Engineering", "Senior", ""),
                       manual("Sam", "Hokie", "Civil Engineering", "Senior", "R1"), close()])
        self.assertCleanRun(run)
        order = [method for method, args in run.dymo_calls
                 if method == "Open" or (method == "SetField" and args[0] == "fn")]
        # once at startup, then before each badge's fields are set
        self.assertEqual(order, ["Open", "Open", "SetField", "Open", "SetField"])


class StartupEventCheckTests(AppTestCase):
    """(a) The startup event check must not crash without network or an API key."""

    def assertWarnedAndUsable(self, run, fragment):
        self.assertCleanRun(run, reads=2)
        self.assertIn("Warning - Could not verify event with Swapcard: " + fragment, run.stdout)
        self.assertEqual(run.window_title, WINDOW_TITLE)
        # the app still prints from manual input
        self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Senior", "RID-1")

    def script(self):
        return [manual("Sam", "Hokie", "Civil Engineering", "Senior", "RID-1"), close()]

    def test_no_network(self):
        err = FakeConnectionError("Failed to resolve 'developer.swapcard.com'")
        run = run_app(self.script(), event_response=err)
        self.assertWarnedAndUsable(run, "Failed to resolve")

    def test_timeout(self):
        run = run_app(self.script(), event_response=FakeReadTimeout("Read timed out. (read timeout=5)"))
        self.assertWarnedAndUsable(run, "Read timed out")

    def test_no_api_key(self):
        env = dict(DEFAULT_ENV)
        del env["PROXY_TOKEN"]
        run = run_app(self.script(), env=env)
        self.assertEqual(run.posts[0]["headers"]["Authorization"], None)
        self.assertWarnedAndUsable(run, "Request status code: 401")

    def test_no_env_at_all(self):
        run = run_app(self.script(), env={})
        self.assertEqual(run.posts[0]["body"], {"lookup": "event"})
        self.assertWarnedAndUsable(run, "Request status code: 401")

    def test_non_json_reply(self):
        run = run_app(self.script(), event_response=FakeResponse(200, NOT_JSON))
        self.assertWarnedAndUsable(run, "Expecting value")


class LookupFailureTests(AppTestCase):
    """(b) Any failure in the Swapcard lookup warns and keeps the loop going."""

    LOOKUP_WARNING = "Warning - Swapcard lookup failed: "

    def run_failure(self, first_event, **kwargs):
        # the failed lookup, then a manual badge to prove the loop kept going
        script = [first_event, manual("Next", "Student", "Civil Engineering", "Senior", "RID-9"), close()]
        return run_app(script, **kwargs)

    def assertSkippedThenContinued(self, run, warning):
        self.assertCleanRun(run, reads=3)
        self.assertIn(warning, run.stdout)
        # nothing was printed for the failed lookup; the next badge printed normally
        self.assertPrintedOnce(run, "Next", "Student", "Civil Engineering", "Senior", "RID-9")
        self.assertEqual(run.stdout.count("NameTag Info"), 1)

    def test_lookup_failures(self):
        def person_with(**kw):
            return {("qrCodes", "SWC-1"): [make_person(barcode="SWC-1", **kw)]}

        no_with_event = make_person(barcode="SWC-1")
        del no_with_event["withEvent"]
        no_first_name = make_person(barcode="SWC-1")
        del no_first_name["firstName"]

        cases = [
            ("connection error", dict(people_response=FakeConnectionError("Max retries exceeded")),
             "Max retries exceeded"),
            ("connect timeout", dict(people_response=FakeConnectTimeout("Connection to host timed out")),
             "Connection to host timed out"),
            ("read timeout", dict(people_response=FakeReadTimeout("Read timed out. (read timeout=5)")),
             "Read timed out"),
            ("HTTP 500 with JSON errors",
             dict(people_response=FakeResponse(500, {"errors": [{"message": "Internal error"}]})), "'data'"),
            ("HTTP 401 with HTML body", dict(people_response=FakeResponse(401, NOT_JSON)), "Expecting value"),
            ("200 with errors and no data",
             dict(people_response=FakeResponse(200, {"errors": [{"message": "Bad filter"}]})), "'data'"),
            ("200 with data null",
             dict(people_response=FakeResponse(200, {"data": None, "errors": [{"message": "x"}]})),
             "not subscriptable"),
            ("200 with eventPerson null", dict(people_response=FakeResponse(200, {"data": {"eventPerson": None}})),
             "not subscriptable"),
            ("no withEvent", dict(people={("qrCodes", "SWC-1"): [no_with_event]}), "'withEvent'"),
            ("no firstName", dict(people={("qrCodes", "SWC-1"): [no_first_name]}), "'firstName'"),
            ("no badges", dict(people=person_with(badges=[])), "list index out of range"),
            ("badge without barcode", dict(people=person_with(badges=[{}])), "'barcode'"),
            ("major is None", dict(people=person_with(major=None)), "student record has no major or year"),
            ("year is None", dict(people=person_with(year=None)), "student record has no major or year"),
            ("major with no translations",
             dict(people=person_with(fields=[{"translations": [], "definition": {"id": MAJOR_ID}}])),
             "list index out of range"),
        ]
        for name, kwargs, detail in cases:
            with self.subTest(name):
                run = self.run_failure(submit(BRID="SWC-1"), **kwargs)
                self.assertSkippedThenContinued(run, self.LOOKUP_WARNING)
                self.assertIn(detail, run.stdout.split(self.LOOKUP_WARNING, 1)[1].splitlines()[0])

    def test_lookup_failure_by_pid(self):
        run = self.run_failure(submit(PID="jdoe1"), people_response=FakeConnectionError("offline"))
        self.assertSkippedThenContinued(run, self.LOOKUP_WARNING + "FakeConnectionError offline")

    def test_non_200_also_logs_status(self):
        run = self.run_failure(submit(BRID="SWC-1"),
                               people_response=FakeResponse(503, NOT_JSON, text="Service Unavailable"))
        self.assertSkippedThenContinued(run, self.LOOKUP_WARNING)
        self.assertIn("Request failed with status code: 503\nError message: Service Unavailable\n", run.stdout)

    def test_unknown_badge_code(self):
        # empty nodes keep the original, more specific warning
        run = self.run_failure(submit(BRID="SWC-UNKNOWN"))
        self.assertSkippedThenContinued(
            run, "Warning - Invaild registration ID. EventPerson can not be resolved.\n")

    def test_unknown_pid(self):
        run = self.run_failure(submit(PID="nobody"))
        self.assertSkippedThenContinued(
            run, "Warning - Invaild PID/VT email. EventPerson can not be resolved.\n")

    def test_no_input(self):
        run = self.run_failure(submit())
        self.assertSkippedThenContinued(run, "Warning - No Input Detected (Content API Query)\n")


class BadgeCodeShapeTests(AppTestCase):
    """Every badge code goes to Swapcard; Hokie Passport scans are no longer special."""

    def test_codes_shaped_like_hokie_passport_go_to_swapcard(self):
        for code in ("a906123456a", "A906123456A", "a906123456b"):
            with self.subTest(code=code):
                run = run_app([submit(BRID=code), close()],
                              people={("qrCodes", code): [make_person(barcode=code)]})
                self.assertCleanRun(run)
                self.assertNotIn("Hokie Passport", run.stdout)
                self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", code)

class WindowCloseAndDebounceTests(AppTestCase):
    """(d) Closing the window is handled before the 3-second scanner debounce."""

    def test_close_right_after_a_badge(self):
        for name, close_event in (("WIN_CLOSED", None), ("Exit", "Exit")):
            with self.subTest(name):
                script = [manual("Sam", "Hokie", "Civil Engineering", "Senior", "R1"),
                          close(dt=0.5, event=close_event)]
                run = run_app(script)
                self.assertCleanRun(run, reads=2)
                self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Senior", "R1")

    def test_close_with_no_badges(self):
        run = run_app([close(dt=0.0)])
        self.assertCleanRun(run, reads=1)
        self.assertEqual(run.set_fields, [])
        # nothing was started, but the exit path still ends any open job
        self.assertEqual(len(run.method_calls("EndPrintJob")), 1)

    def test_debounce_still_drops_fast_repeats(self):
        # dt values are exact binary fractions so the 3.0 s boundary is not a float-rounding coin flip
        script = [
            manual("A", "One", "Civil Engineering", "Senior", "R1", dt=10.0),
            manual("B", "Two", "Civil Engineering", "Senior", "R2", dt=1.0),     # 1.0 s later: dropped
            manual("C", "Three", "Civil Engineering", "Senior", "R3", dt=1.75),  # 2.75 s: dropped
            manual("D", "Four", "Civil Engineering", "Senior", "R4", dt=0.25),   # 3.0 s: printed
            close(dt=0.125),
        ]
        run = run_app(script)
        self.assertCleanRun(run, reads=5)
        self.assertEqual([v for k, v in run.set_fields if k == "fn"], ["A", "D"])
        self.assertEqual(len(run.method_calls("Print")), 2)


class PrinterSetupTests(AppTestCase):
    """(e) Printer setup failures disable printing without crashing."""

    def assertNoPrinter(self, run, message):
        self.assertCleanRun(run, reads=2)
        self.assertIn("No Printer Found  " + message + "\n", run.stdout)
        self.assertIsNone(run.globals["printer"])
        self.assertIsNone(run.globals["label"])
        self.assertEqual(run.set_fields, [])
        self.assertEqual(run.method_calls("StartPrintJob"), [])
        self.assertEqual(run.method_calls("EndPrintJob"), [], "no EndPrintJob when there is no printer")
        # the badge info is still shown in the console
        self.assertIn(nametag_block("Sam", "Hokie", "Civil Engineering", "Senior", "R1"), run.stdout)
        self.assertNotIn("Print Success", run.stdout)

    def script(self):
        return [manual("Sam", "Hokie", "Civil Engineering", "Senior", "R1"), close()]

    def test_no_printers(self):
        for value in ("", None):
            with self.subTest(printers=value):
                run = run_app(self.script(), printers=value)
                self.assertNoPrinter(run, "no DYMO printers found")
                self.assertNotIn("printer_list", run.stdout)
                self.assertNotIn("is not defined", run.stdout)
                self.assertNotIn("Selected:", run.stdout)
                self.assertEqual(run.method_calls("SelectPrinter"), [])
                self.assertEqual(run.method_calls("Open"), [])

    def test_open_returns_false(self):
        run = run_app(self.script(), open_result=False)
        self.assertNoPrinter(run, "could not open label file: " + LABEL_FILE)

    def test_open_raises(self):
        run = run_app(self.script(), open_result=OSError("label file is locked"))
        self.assertNoPrinter(run, "label file is locked")

    def test_dymo_software_not_installed(self):
        run = run_app(self.script(), dispatch_error=OSError("Invalid class string"))
        self.assertNoPrinter(run, "Invalid class string")
        self.assertIn("Before Dispatch\n", run.stdout)
        self.assertNotIn("After Dispatch", run.stdout)

    def test_open_result_none_or_true_keeps_printing(self):
        for value in (None, True, 1):
            with self.subTest(open_result=value):
                run = run_app(self.script(), open_result=value)
                self.assertCleanRun(run)
                self.assertNotIn("No Printer Found", run.stdout)
                self.assertIsNotNone(run.globals["printer"])
                self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Senior", "R1")

    def test_open_gets_absolute_label_path_string(self):
        run = run_app(self.script())
        self.assertCleanRun(run)
        (path,), (again,) = run.method_calls("Open")  # at startup, then before the badge
        self.assertEqual(again, path)
        self.assertIsInstance(path, str)
        self.assertTrue(os.path.isabs(path))
        self.assertEqual(norm(path), norm(LABEL_FILE))
        self.assertTrue(os.path.isfile(path))

    def test_first_of_several_printers_is_selected(self):
        run = run_app(self.script(), printers="DYMO LabelWriter 450|DYMO LabelWriter 450 Turbo")
        self.assertCleanRun(run)
        self.assertEqual(run.method_calls("SelectPrinter"), [("DYMO LabelWriter 450",)])
        self.assertIn("Selected:DYMO LabelWriter 450\n", run.stdout)


class EndPrintJobTests(AppTestCase):
    """(f) EndPrintJob failures warn, and the window still closes."""

    END_WARNING = "Warning - Could not end print job: no active print job\n"

    def test_print_fails_and_end_print_job_fails(self):
        script = [manual("A", "One", "Civil Engineering", "Senior", "R1"),
                  manual("B", "Two", "Civil Engineering", "Senior", "R2"), close()]
        run = run_app(script, print_error=RuntimeError("printer offline"),
                      end_print_error=RuntimeError("no active print job"))
        self.assertCleanRun(run, reads=3)
        # one warning per failed job (2) plus one on exit
        self.assertEqual(run.stdout.count(self.END_WARNING), 3)
        self.assertEqual(run.stdout.count("\nPrinting Not Resolved -  printer offline \n"), 2)
        self.assertEqual([v for k, v in run.set_fields if k == "fn"], ["A", "B"], "loop kept going")
        self.assertTrue(run.stdout.rstrip("\n").endswith(self.END_WARNING.rstrip("\n")))

    def test_only_the_exit_end_print_job_fails(self):
        script = [manual("A", "One", "Civil Engineering", "Senior", "R1"), close()]
        run = run_app(script, end_print_error=RuntimeError("no active print job"), end_print_fail_on={2})
        self.assertCleanRun(run, reads=2)
        self.assertIn("\nPrint Success\n", run.stdout)
        self.assertEqual(run.stdout.count(self.END_WARNING), 1)
        self.assertEqual(len(run.method_calls("EndPrintJob")), 2)

    def test_setfield_fails(self):
        script = [manual("A", "One", "Civil Engineering", "Senior", "R1"), close()]
        run = run_app(script, setfield_error=RuntimeError("no such field"))
        self.assertCleanRun(run, reads=2)
        self.assertIn("\nPrinting Not Resolved -  no such field \n", run.stdout)
        self.assertNotIn("Warning - Could not end print job", run.stdout)
        self.assertEqual(run.method_calls("StartPrintJob"), [])
        self.assertEqual(len(run.method_calls("EndPrintJob")), 2)


class ConfigPathTests(AppTestCase):
    """(g) config.py paths from source and when frozen by PyInstaller."""

    def import_config(self, **kwargs):
        run = AppRun().run(target="config", **kwargs)
        self.assertIsNone(run.error, run.tb)
        return run

    def assertPaths(self, config, app_dir, resource_dir):
        self.assertEqual(norm(config.APP_DIR), norm(app_dir))
        self.assertEqual(norm(config.RESOURCE_DIR), norm(resource_dir))
        self.assertEqual(norm(config.ENV_PATH), norm(os.path.join(app_dir, ".env")))
        self.assertEqual(norm(config.LABEL_PATH),
                         norm(os.path.join(resource_dir, "src", "label", "student_badge_v3.label")))

    def test_from_source(self):
        run = self.import_config()
        self.assertPaths(run.module, REPO_ROOT, REPO_ROOT)
        self.assertEqual(norm(run.module.LABEL_PATH), norm(LABEL_FILE))
        self.assertTrue(os.path.isfile(run.module.LABEL_PATH))
        self.assertEqual(run.dotenv_calls, [((run.module.ENV_PATH,), {})])

    def test_from_source_ignores_cwd(self):
        with tempfile.TemporaryDirectory() as elsewhere:
            run = self.import_config(cwd=elsewhere)
        self.assertPaths(run.module, REPO_ROOT, REPO_ROOT)

    def test_frozen(self):
        exe_dir = r"C:\Program Files\Engineering Expo Nametags"
        meipass = r"C:\Users\student\AppData\Local\Temp\_MEI123452"
        run = self.import_config(frozen={"executable": os.path.join(exe_dir, "ExpoNametags.exe"),
                                         "meipass": meipass})
        self.assertPaths(run.module, exe_dir, meipass)
        self.assertEqual(run.dotenv_calls, [((os.path.join(exe_dir, ".env"),), {})])

    def test_frozen_without_meipass(self):
        exe_dir = r"C:\Program Files\Engineering Expo Nametags"
        run = self.import_config(frozen={"executable": os.path.join(exe_dir, "ExpoNametags.exe")})
        self.assertPaths(run.module, exe_dir, exe_dir)

    def test_main_from_another_cwd(self):
        with tempfile.TemporaryDirectory() as elsewhere:
            run = run_app([manual("Sam", "Hokie", "Civil Engineering", "Senior", "R1"), close()], cwd=elsewhere)
        self.assertCleanRun(run)
        self.assertEqual(run.open_paths, [norm(LABEL_FILE)] * 2)  # at startup, then before the badge
        self.assertEqual(run.dotenv_calls, [((os.path.join(REPO_ROOT, ".env"),), {})])
        self.assertPrintedOnce(run, "Sam", "Hokie", "Civil Engineering", "Senior", "R1")

    def test_settings_come_from_the_env_file(self):
        # nothing in the environment; config's load_dotenv(ENV_PATH) supplies all four values,
        # and main.py must read SWAPCARD_MAJOR_ID / SWAPCARD_YEAR_ID after that
        run = run_app([submit(BRID="SWC-7Q2M9XP"), close()], env={}, dotenv_values=DEFAULT_ENV,
                      people={("qrCodes", "SWC-7Q2M9XP"): [make_person()]})
        self.assertCleanRun(run)
        self.assertEqual(run.dotenv_calls, [((os.path.join(REPO_ROOT, ".env"),), {})])
        self.assertNotIn("Warning", run.stdout)
        self.assertEqual(run.posts[0]["headers"]["Authorization"], API_KEY)
        self.assertEqual(run.posts[0]["body"], {"lookup": "event"})
        self.assertPrintedOnce(run, "Jane", "Doe", "Mechanical Engineering", "Junior", "SWC-7Q2M9XP")

    def test_main_frozen(self):
        exe_dir = r"C:\Program Files\Engineering Expo Nametags"
        meipass = r"C:\Users\student\AppData\Local\Temp\_MEI123452"
        run = run_app([close()], frozen={"executable": os.path.join(exe_dir, "ExpoNametags.exe"),
                                         "meipass": meipass})
        self.assertCleanRun(run)
        self.assertEqual(run.method_calls("Open"),
                         [(os.path.join(meipass, "src", "label", "student_badge_v3.label"),)])
        # main.py no longer calls load_dotenv itself; config loads the install folder's .env once
        self.assertEqual(run.dotenv_calls, [((os.path.join(exe_dir, ".env"),), {})])


if __name__ == "__main__":
    unittest.main()
