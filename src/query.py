import requests
from config import QueryConfig, EXPOEventNotFoundError

URL = QueryConfig.url
headers = QueryConfig.headers

# Both lookups go to the Cloudflare Worker (proxy/worker.js). It builds the Swapcard
# query itself and answers in Swapcard's JSON format, so main.py reads it unchanged.

def event_query():

    response = requests.post(url=URL, headers=headers,
                             json={'lookup': 'event'}, timeout=5)

    # Check if the request was successful
    if not response.status_code == 200:
        # Raise the error if the request failed
        raise EXPOEventNotFoundError(response.status_code, response.text)

    return response


def people_filter_query(filters):

    response = requests.post(url=URL, headers=headers,
                             json={'lookup': 'person', 'filters': filters}, timeout=5)

    # Check if the request was successful
    if not response.status_code == 200:
        # Print the error message if the request failed
        print('Request failed with status code:', response.status_code)
        print('Error message:', response.text)

    return response
