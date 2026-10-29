// Expo Nametag Printing lookup service (a Cloudflare Worker).
//
// It holds the Swapcard API key so volunteer laptops never get it. A laptop can only ask
// the two questions below, and only with the laptop token. Setup steps: proxy/README.md.
//
// Settings (Cloudflare dashboard > this Worker > Settings > Variables and Secrets):
//   SWAPCARD_API_KEY   Secret  the Swapcard Studio API key for this year's Expo
//   SWAPCARD_EVENT_ID  Text    this year's Swapcard event ID
//   LAPTOP_TOKEN       Secret  a long random password; laptops send it as PROXY_TOKEN
//
// Laptops POST JSON with the header "Authorization: <LAPTOP_TOKEN>":
//   {"lookup": "event"}                                   is the event there?
//   {"lookup": "person", "filters": {"qrCodes": "..."}}   find a student by badge code
//   {"lookup": "person", "filters": {"emails": "..."}}    or by email
// The answer is Swapcard's own JSON, with only the fields a badge needs.

const SWAPCARD_URL = "https://developer.swapcard.com/event-admin/graphql";

const EVENT_QUERY = `
  query EventById($eventId: ID!) {
    event(id: $eventId) { id title beginsAt endsAt }
  }`;

// Major and year are select fields; the app matches them by definition id
// (SWAPCARD_MAJOR_ID / SWAPCARD_YEAR_ID in the laptop's settings file).
const PERSON_QUERY = `
  query eventPerson($eventId: ID!, $filters: [EventPersonFilter!]) {
    eventPerson(eventId: $eventId, filters: $filters) {
      nodes {
        firstName
        lastName
        withEvent(eventId: $eventId) {
          fields {
            ... on MultipleSelectField { translations { value } definition { id } }
            ... on SelectField { translations { value } definition { id } }
          }
          badges { ... on BadgeBarcode { barcode } }
        }
      }
    }
  }`;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return reply(405, "Use POST");
    }
    if (!env.LAPTOP_TOKEN || request.headers.get("Authorization") !== env.LAPTOP_TOKEN) {
      return reply(401, "Wrong or missing laptop token");
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return reply(400, "The request body must be JSON");
    }

    const variables = { eventId: env.SWAPCARD_EVENT_ID };
    let query;
    if (body.lookup === "event") {
      query = EVENT_QUERY;
    } else if (body.lookup === "person" && isOneFilter(body.filters)) {
      query = PERSON_QUERY;
      variables.filters = body.filters;
    } else {
      return reply(400, "Unknown lookup");
    }

    const swapcard = await fetch(SWAPCARD_URL, {
      method: "POST",
      headers: {
        "Authorization": env.SWAPCARD_API_KEY,
        "Content-Type": "application/json",
        "Accept": "application/json",
      },
      body: JSON.stringify({ query, variables }),
    });
    return new Response(swapcard.body, {
      status: swapcard.status,
      headers: { "Content-Type": "application/json" },
    });
  },
};

// Allows exactly {"qrCodes": "<code>"} or {"emails": "<email>"} with one short text value.
function isOneFilter(filters) {
  if (!filters || typeof filters !== "object" || Array.isArray(filters)) {
    return false;
  }
  const keys = Object.keys(filters);
  if (keys.length !== 1 || (keys[0] !== "qrCodes" && keys[0] !== "emails")) {
    return false;
  }
  const value = filters[keys[0]];
  return typeof value === "string" && value.length > 0 && value.length <= 200;
}

function reply(status, message) {
  return new Response(JSON.stringify({ errors: [{ message }] }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
