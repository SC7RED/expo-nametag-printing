import os
import sys

from dotenv import load_dotenv

# APP_DIR is the install folder (where .env lives). RESOURCE_DIR is where bundled
# data such as the label file lives (PyInstaller's _MEIPASS folder when frozen).
# Running from source, both are the repo root.
if getattr(sys, "frozen", False):
    APP_DIR = os.path.dirname(sys.executable)
    RESOURCE_DIR = getattr(sys, "_MEIPASS", APP_DIR)
else:
    APP_DIR = RESOURCE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_PATH = os.path.join(APP_DIR, ".env")
LABEL_PATH = os.path.join(RESOURCE_DIR, "src", "label", "student_badge_v3.label")

class GeneralConfig:

    CURRENT_YEAR = 2026

    # query structure keys
    DATA = "data"
    EVENT_PERSON = "eventPerson"
    NODE = "nodes"
    FIRST_NAME = "firstName"
    LAST_NAME = "lastName"
    DEFINITION = "definition"
    TRANSLATION = "translations"

class NameTagConfig:

    years = [
        "Freshman",
        "Sophomore",
        "Junior",
        "Senior",
        "Masters",
        "Doctorate"
        ]

    majors = [
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
        "Non-Engineering"
        ]

    major_index = {
        "AE": 0,
        "BSE": 1,
        "BME": 2,
        "BUC": 3,
        "CHE": 4,
        "CVE": 5,
        "CPE": 6,
        "CS": 7,
        "CEM": 8,
        "EE": 9,
        "ESM": 10,
        "GE": 11,
        "ISE": 12,
        "MSE": 13,
        "ME": 14,
        "OE": 15,
        "NON": 16
    }

# A bad .env must not stop the window from opening. Only the error type is printed,
# so nothing from the file ends up on screen.
try:
    load_dotenv(ENV_PATH)
except (OSError, UnicodeDecodeError) as err:
    print("Warning - Could not read .env:", type(err).__name__)

class QueryConfig:

    # Lookups go to our Cloudflare Worker (see proxy/README.md), which holds the real
    # Swapcard API key and event ID. PROXY_TOKEN is the Worker's laptop token, not the Swapcard key.
    url = os.getenv('PROXY_URL')
    headers = {
        'Authorization': os.getenv('PROXY_TOKEN'),
        'Accept': 'application/json'
    }

class EXPOEventNotFoundError(Exception):

    def __init__(self, status_code: int, message: str) -> None:

        self.status_code = status_code
        self.message = 'Request status code: ' + str(self.status_code) + '\n' + message
        super().__init__(self.message)
