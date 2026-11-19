import time

import FreeSimpleGUI as sg
from win32com.client import Dispatch

import query  # imports config first, which loads .env
from config import GeneralConfig, NameTagConfig, QueryConfig, LABEL_PATH


DEFAULT_FONT = ("Calibri", 22)
INPUT_FONT = ("Courier", 20)
TEXT_SIZE = (15, 1)


# helper functions (the app itself starts at "verify event" below)
def _make_label(text_content):
    return sg.Text(text=text_content, size=TEXT_SIZE, font=INPUT_FONT)

def _printer_set_up():
    try:
        print("Before Dispatch")
        dymo_printer = Dispatch("Dymo.DymoAddIn")
        print("After Dispatch")
        printers_string = dymo_printer.GetDymoPrinters()
        print(printers_string)
        if not printers_string:
            raise RuntimeError("no DYMO printers found")
        printer_list = printers_string.split('|')
        dymo_printer.SelectPrinter(printer_list[0])
        print("Selected:" + printer_list[0])

        # Only an explicit False is a failure; late-bound COM calls can return None on success
        if dymo_printer.Open(LABEL_PATH) is False:
            raise RuntimeError("could not open label file: " + LABEL_PATH)
        dymo_label = Dispatch("Dymo.DymoLabels")

    except Exception as dymo_err:
        dymo_printer = None
        dymo_label = None
        print("No Printer Found ", dymo_err)

    return dymo_printer, dymo_label

def _end_print_job():
    try:
        printer.EndPrintJob()
    except Exception as end_err:
        print("Warning - Could not end print job:", end_err)

# Finds the student on Swapcard by badge code (Option 1) or VT PID/email (Option 2).
# Returns [first name, last name, major, year, registration ID], or None after a warning.
def lookup_student(inputs):
    if inputs['BRID'] != '':
        people_filter = {'qrCodes': inputs['BRID']}
        not_found = "Warning - Invalid registration ID. EventPerson can not be resolved."
    elif inputs['PID'] != '':
        pid = inputs['PID'] if '@' in inputs['PID'] else inputs['PID'] + '@vt.edu'
        people_filter = {'emails': pid}
        not_found = "Warning - Invalid PID/VT email. EventPerson can not be resolved."
    else:
        print("Warning - No Input Detected (Content API Query)")
        return None

    try:
        # The reply's shape is set by PERSON_QUERY in proxy/worker.js
        result = query.people_filter_query(people_filter).json()
        print(result)
        people = result['data']['eventPerson']['nodes']
        if people == []:
            print(not_found)
            return None

        person = people[0]
        first_name = person['firstName']
        last_name = person['lastName']

        # Major and year are select fields, matched by the field IDs from .env. Each option
        # picked in a multiple-select field is its own entry, so for a double major the
        # last major listed is used.
        major, year = '', ''
        for field in person['withEvent']['fields']:
            if 'definition' in field and field['definition']['id'] == QueryConfig.major_id:
                major = field['translations'][0]['value']
            if 'definition' in field and field['definition']['id'] == QueryConfig.year_id:
                year = field['translations'][0]['value']

        regis_id = person['withEvent']['badges'][0]['barcode']

        # a Freshman with no major is fine: apply_special_cases prints General Engineering
        if not year or (not major and "freshman" not in year.lower()):
            raise ValueError("student record has no major or year")

    except Exception as err:
        print("Warning - Swapcard lookup failed:", type(err).__name__, err)
        return None

    return [first_name, last_name, major, year, regis_id]

# Returns the major to print: every freshman is General Engineering, and Swapcard's names
# for a few majors become the names in the Major list.
def apply_special_cases(major, year):
    if "freshman" in year.lower():
        major = "General Engineering"

    if "construction" in major.lower() and "management" in major.lower():
        major = "Construction Engineering (CEM)"

    if "computer" in major.lower() and "science" in major.lower():
        major = "Computer Science"

    if "building" in major.lower() and "construction" in major.lower():
        major = "Building Construction"

    return major

# Prints one badge with the printer and label set up at startup (see below).
def print_badge(first_name, last_name, major, year, regis_id):
    try:
        # Start every badge from the saved design: once a field has been set to empty
        # text, DYMO prints that field in a small default font until the label is reopened.
        if printer.Open(LABEL_PATH) is False:
            raise RuntimeError("could not open label file: " + LABEL_PATH)

        label.SetField("fn", first_name)
        label.SetField("ln", last_name)
        label.SetField("y", year)
        label.SetField("m", major)
        label.SetField("BARCODE", regis_id)

        printer.StartPrintJob()
        printer.Print(1, False)
        printer.EndPrintJob()

        print("\nPrint Success\n")

    except Exception as err:
        _end_print_job()
        print("\nPrinting Not Resolved - ", err, "\n")


# verify event
try:
    print(query.event_query().json())
except Exception as err:
    print("Warning - Could not verify event with Swapcard:", err)

# set up simple GUI
sg.theme("SystemDefaultForReal")
sg.set_options(font=DEFAULT_FONT)

# printer dispatch
printer, label = _printer_set_up()

# design the GUI
input1 = [_make_label("Badge Code"), sg.InputText(do_not_clear=False, key="BRID")]
input2 = [_make_label("VT PID"), sg.InputText(do_not_clear=False, key="PID")]

backup_fn = [_make_label("First Name"), sg.InputText(do_not_clear=False, key="FN")]
backup_ln = [_make_label("Last Name"), sg.InputText(do_not_clear=False, key="LN")]
backup_major = [_make_label("Major"),
                sg.Combo(list(NameTagConfig.majors), default_value=NameTagConfig.majors[0], key="MJ")]
backup_year = [_make_label("Year"),
               sg.Combo(list(NameTagConfig.years), default_value="Freshman", key="YR")]
backup_r_id = [_make_label("Registration ID"),
               sg.InputText(do_not_clear=False, default_text="", key="RID")]
backup = [backup_fn, backup_ln, backup_major, backup_year, backup_r_id]

layout = [
    [sg.Text("Option 1 - Scan Swapcard Badge Code or the Code from their Confirmation Email")], input1,
    [sg.Text("Option 2 - Input VT PID")], input2,
    [sg.Checkbox("Manual Input Backup (enable by checkbox)", key="manual_input")], *backup,
    [sg.Submit(), sg.Text("Please only exit this program by closing the window.", text_color="red")]
]
screen_size = sg.Window.get_screen_size()
print(f"Window Size: {screen_size}")
window = sg.Window(str(GeneralConfig.CURRENT_YEAR) + " Engineering Expo Student Nametag Printing",
                   layout, size=screen_size)

# time of the last badge, for the double-scan guard below
last_badge_time = 0

while True:
    event, inputs = window.read()

    if event in (sg.WIN_CLOSED, 'Exit'):
        break

    # Because the scanner scans so fast, we need to add a delay so that the scanner
    # doesn't print multiple of the same nametag.
    if time.time() - last_badge_time < 3:
        continue
    last_badge_time = time.time()

    if inputs["manual_input"]:
        # Parse directly from manual inputs
        student = [inputs[k] for k in ('FN', 'LN', 'MJ', 'YR', 'RID')]
    else:
        # Parse information from the Swapcard lookup
        student = lookup_student(inputs)
        if student is None:
            continue

    first_name, last_name, major, year, regis_id = student
    major = apply_special_cases(major, year)

    # Terminal output for student info
    print('#'*10 + ' NameTag Info ' + '#'*10 +
        f"\n{'First Name:':<20}{first_name}" + f"\n{'Last Name:':<20}{last_name}" +
        f"\n{'Major:':<20}{major}" + f"\n{'Year:':<20}{year}" +
        f"\n{'Registration ID:':<20}{regis_id}\n")

    if printer is not None and label is not None:
        print_badge(first_name, last_name, major, year, regis_id)

if printer is not None:
    _end_print_job()
window.close()
