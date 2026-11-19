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

# A bad .env must not stop the window from opening. Only the error type is printed,
# so nothing from the file ends up on screen.
try:
    load_dotenv(ENV_PATH)
except (OSError, UnicodeDecodeError) as err:
    print("Warning - Could not read .env:", type(err).__name__)

class GeneralConfig:

    CURRENT_YEAR = 2026

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

class QueryConfig:

    # Lookups go to our Cloudflare Worker (see proxy/README.md), which holds the real
    # Swapcard API key and event ID. PROXY_TOKEN is the Worker's laptop token, not the Swapcard key.
    url = os.getenv('PROXY_URL')
    headers = {
        'Authorization': os.getenv('PROXY_TOKEN'),
        'Accept': 'application/json'
    }

    # IDs of this year's Swapcard Major and School Year fields (proxy/Get-SwapcardFieldIds.ps1 lists them)
    major_id = os.getenv('SWAPCARD_MAJOR_ID')
    year_id = os.getenv('SWAPCARD_YEAR_ID')
