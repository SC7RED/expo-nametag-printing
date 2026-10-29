from datetime import datetime
import time

#import gspread
import FreeSimpleGUI as sg
from win32com.client import Dispatch

import query  # imports config first, which loads .env
from config import GeneralConfig, NameTagConfig, LABEL_PATH

import os


# Globals
DATA = GeneralConfig.DATA
EVENT_PERSON = GeneralConfig.EVENT_PERSON
NODE = GeneralConfig.NODE
FIRST_NAME = GeneralConfig.FIRST_NAME
LAST_NAME = GeneralConfig.LAST_NAME
DEFINITION = GeneralConfig.DEFINITION
TRANSLATION = GeneralConfig.TRANSLATION

MAJOR_ID = os.getenv('SWAPCARD_MAJOR_ID')
YEAR_ID = os.getenv('SWAPCARD_YEAR_ID')
DEFAULT_FONT = ("Calibri", 22)
INPUT_FONT = ("Courier", 20)
TEXT_SIZE = (15, 1)

# verify event
try:
    event = query.event_query().json()
    print(event)
except Exception as err:
    print("Warning - Could not verify event with Swapcard:", err)

# set up simple GUI
sg.theme("SystemDefaultForReal")
sg.set_options(font=DEFAULT_FONT)

# private utility functions
def _text_creater(text_content):
    return sg.Text(text=text_content, size=TEXT_SIZE, font=INPUT_FONT)

def _printer_set_up():
    try:
        print("Before Dispatch")
        dymo_printer = Dispatch("Dymo.DymoAddIn")
        print ("After Dispatch")
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

# printer dispatch
printer, label = _printer_set_up()

# design the GUI
input1 = [_text_creater("Badge Code"), sg.InputText(do_not_clear=False, key="BRID")]
input2 = [_text_creater("VT PID"), sg.InputText(do_not_clear=False, key="PID")]

backup_fn = [_text_creater("First Name"), sg.InputText(do_not_clear=False, key="FN")]
backup_ln = [_text_creater("Last Name"), sg.InputText(do_not_clear=False, key="LN")]
backup_major = [_text_creater("Major"),
            sg.Combo(list(NameTagConfig.majors), default_value=NameTagConfig.majors[0], key="MJ")]
backup_year = [_text_creater("Year"),
            sg.Combo(list(NameTagConfig.years), default_value="Freshman", key="YR")]
backup_r_id = [_text_creater("Registration ID"),
             sg.InputText(do_not_clear=False, default_text="", key="RID")]
backup = [backup_fn, backup_ln, backup_major, backup_year, backup_r_id]

layout = [
    [sg.Text("Option 1 - Scan Swapcard Badge Code or the Code from their Confirmation Email")], input1,
    [sg.Text("Option 2 - Input VT PID")], input2,
    [sg.Checkbox("Manual Input Backup (enable by checkbox)", key="manual_input")], *backup,
    [sg.Submit(), sg.Text("Please only exit this program by closing the window.",text_color="red")]
]
print(f"Window Size: {sg.Window.get_screen_size()}")
window = sg.Window(str(GeneralConfig.CURRENT_YEAR) + " Engineering Expo Student Nametag Printing",
                   layout, size=sg.Window.get_screen_size())

# record start time as timestamp for a previous event
timePrev = 0

while True:
    event, inputs = window.read()

    if event in (sg.WIN_CLOSED, 'Exit'):
        break

    # Beacuse the scanner scans so fast, we need to add a delay so that the scanner doesnt print multiple of the same nametag.
    if time.time() - timePrev >= 3:
        timePrev = time.time()

        first_name, last_name, major, year, regis_id = '', '', '', '', ''

        # Parse information from SwapCard API queries
        if not inputs["manual_input"]:
            try:
                # Option 1 - Search by registration ID
                if not inputs['BRID'] == '':
                    people_filter = {'qrCodes': inputs['BRID']}
                    person = query.people_filter_query(people_filter)
                    print(person.json())

                    if person.json()[DATA][EVENT_PERSON][NODE] == []:
                        print("Warning - Invaild registration ID. EventPerson can not be resolved.")
                        continue

                # Option 2 - Search by PID or VT email
                elif not inputs['PID'] == '':
                    pid = inputs['PID'] if '@' in inputs['PID'] else inputs['PID'] + '@vt.edu'
                    people_filter = {'emails': pid}
                    person = query.people_filter_query(people_filter)
                    print(person.json())

                    if person.json()[DATA][EVENT_PERSON][NODE] == []:
                        print("Warning - Invaild PID/VT email. EventPerson can not be resolved.")
                        continue

                else:
                    print("Warning - No Input Detected (Content API Query)")
                    continue

                eventPerson = person.json()[DATA][EVENT_PERSON][NODE][0]
                # assign from the query result
                first_name = eventPerson[FIRST_NAME]
                last_name = eventPerson[LAST_NAME]

                # Fetch major & year from fields - only the first major is recorded
                fields = eventPerson['withEvent']['fields']
                # first_major_flag = True
                for field in fields:
                    # if first_major_flag and DEFINITION in field and field[DEFINITION][TRANSLATION][0]['name'] == 'Major':
                    if (DEFINITION in field and field[DEFINITION]['id'] ==  MAJOR_ID):
                        # MultipleSelectField query structure
                        major = field[TRANSLATION][0]['value']

                    # if DEFINITION in field and field[DEFINITION][TRANSLATION][0]['name'] == 'School Year':
                    if (DEFINITION in field and field[DEFINITION]['id'] == YEAR_ID):

                        # SelectField query structure
                        year = field[TRANSLATION][0]['value']

                    # if not inputs["OWGLConfirm"] and DEFINITION in field and field[DEFINITION][TRANSLATION][0]['name'] == 'Graduation Year':
                    #     # SelectField query structure
                    #     graduation_time = field[TRANSLATION][0]['value']
                    #     if not graduation_time == "None" or not graduation_time == "Other":
                    #         graduation_year = int(graduation_time[-4:])
                    #         if "Spring" in graduation_time:
                    #             graduation_year -= 1
                    #         year = NameTagConfig.years[3 + GeneralConfig.CURRENT_YEAR - graduation_year]

                    #     else: year = graduation_time

                badges = eventPerson['withEvent']['badges']
                regis_id = badges[0]['barcode']

                # a Freshman with no major is fine: the special cases below print General Engineering
                if year is None or (major is None and "freshman" not in year.lower()):
                    raise ValueError("student record has no major or year")

            except Exception as err:
                print("Warning - Swapcard lookup failed:", type(err).__name__, err)
                continue

        # Parse directly from manual inputs
        else:
            first_name, last_name, major, year, regis_id = \
                [inputs[k] for k in ('FN', 'LN', 'MJ', 'YR', 'RID')]

        # Special cases assignments
        if "freshman" in year.lower():
            major = NameTagConfig.majors[NameTagConfig.major_index["GE"]]

        if "construction" in major.lower() and "management" in major.lower():
            major = NameTagConfig.majors[NameTagConfig.major_index["CEM"]]

        if "computer" in major.lower() and "science" in major.lower():
            major = NameTagConfig.majors[NameTagConfig.major_index["CS"]]

        if "building" in major.lower() and "construction" in major.lower():
            major = NameTagConfig.majors[NameTagConfig.major_index["BUC"]]

        # Terminal output for student info
        print('#'*10 + ' NameTag Info ' + '#'*10 +
            f"\n{'First Name:':<20}{first_name}" + f"\n{'Last Name:':<20}{last_name}" +
            f"\n{'Major:':<20}{major}" + f"\n{'Year:':<20}{year}" +
            f"\n{'Registration ID:':<20}{regis_id}\n")

        # Log the query or inputed student record to a pre-established Google Sheet
        now_datetime = datetime.now()
        now_date = now_datetime.strftime("%m/%d/%Y")
        now_time = now_datetime.strftime("%H:%M:%S")
        organized_data = [[now_date, now_time, first_name, last_name, major, year, regis_id]]
        #work_sheet.update(_cell_range(row_insert), organized_data)

        # Terminal output for Google Sheet log Confirmation
        print('#'*10 + ' Query Logged ' + '#'*10 + '\n')

        if printer is not None and label is not None:
            try:
                # Print job
                label.SetField("fn", first_name)
                label.SetField("ln", last_name)
                # label.SetField("ln_1", '')
                label.SetField("y", year)
                label.SetField("m", major)
                label.SetField("BARCODE", regis_id)

                printer.StartPrintJob()
                printer.Print(1, False)
                printer.EndPrintJob()

                print("\nPrint Success\n")

            except Exception as err:
                try:
                    printer.EndPrintJob()
                except Exception as end_err:
                    print("Warning - Could not end print job:", end_err)
                print("\nPrinting Not Resolved - ", err, "\n")

        # Index increment
        #row_insert += 1

#work_sheet.update('A' + str(row_insert), GeneralConfig.GOOGLE_LOG_END_TOKEN)
if printer is not None:
    try:
        printer.EndPrintJob()
    except Exception as end_err:
        print("Warning - Could not end print job:", end_err)
window.close()
