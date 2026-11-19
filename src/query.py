import requests
from config import QueryConfig

# Both lookups go to the Cloudflare Worker (proxy/worker.js). It builds the Swapcard
# query itself and answers in Swapcard's JSON format, so main.py reads it unchanged.

# One session for every lookup keeps the connection to the Worker open between scans,
# which makes each lookup after the first about 0.3 s faster.
session = requests.Session()
session.headers.update(QueryConfig.headers)


class EXPOEventNotFoundError(Exception):

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__('Request status code: ' + str(status_code) + '\n' + message)


def _post(body):
    try:
        return session.post(QueryConfig.url, json=body, timeout=5)
    except requests.ConnectTimeout:
        raise  # the network is down or very slow: don't wait twice
    except requests.ConnectionError:
        # The connection kept open since the last lookup can go stale (Wi-Fi change,
        # laptop asleep), and then fails at once. Try once more on a new connection.
        return session.post(QueryConfig.url, json=body, timeout=5)


def event_query():

    response = _post({'lookup': 'event'})

    # Check if the request was successful
    if not response.status_code == 200:
        # Raise the error if the request failed
        raise EXPOEventNotFoundError(response.status_code, response.text)

    return response


def people_filter_query(filters):

    response = _post({'lookup': 'person', 'filters': filters})

    # Check if the request was successful
    if not response.status_code == 200:
        # Print the error message if the request failed
        print('Request failed with status code:', response.status_code)
        print('Error message:', response.text)

    return response
