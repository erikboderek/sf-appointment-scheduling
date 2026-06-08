# sf-appointment-scheduling

Five invocable Apex classes that implement a complete appointment scheduling flow for Salesforce Field Service. Designed for use in **Agentforce topics**, **Flows**, or any invocable context.

---

## What It Does

| Class | Purpose |
|---|---|
| `EA_LocationFinder` | Geocodes any address, city, or ZIP and returns up to 3 nearby Service Territories sorted by distance |
| `EA_SlotFinder` | Returns the next 3 available appointment slots for a territory and work type (Mon–Fri, 9 AM–5 PM) |
| `EA_CaptureSlot` | Resolves the customer's slot choice (1, 2, or 3) into concrete ISO start/end times |
| `EA_AppointmentBooking` | Creates a ServiceAppointment and finds or creates a PersonAccount (deduped by phone) |
| `EA_AppointmentReschedule` | Looks up or reschedules an existing appointment by confirmation number |

### Typical Flow
1. Customer provides a location → **EA_LocationFinder** returns nearby offices
2. Customer picks a location → **EA_SlotFinder** returns available time slots
3. Customer picks a slot → **EA_CaptureSlot** resolves the chosen start/end times
4. **EA_AppointmentBooking** creates the appointment and returns a confirmation number
5. Customer can look up or reschedule later via **EA_AppointmentReschedule**

---

## Requirements

- Salesforce org with **Field Service** enabled
- **ServiceTerritory** records that are active and have Latitude/Longitude populated
- **WorkType** records configured in your org
- **Person Accounts** enabled (Setup > Account Settings)
- **Salesforce Maps** managed package installed — required for geocoding in `EA_LocationFinder`; falls back gracefully to returning all territories if absent
- API version 62.0+

---

## Deploy

```bash
sf project deploy start --source-dir force-app --target-org <your-org-alias>
```

---

## Possible Issues

**Geocoding falls back silently** — If Salesforce Maps is not installed, `EA_LocationFinder` skips distance filtering and returns all active territories alphabetically rather than throwing an error.

**WorkType name must match exactly** — `EA_SlotFinder` queries WorkType by Name (case-sensitive). A mismatch returns an error message in `errorMessage`. Run `SELECT Name FROM WorkType` in the Query Editor to find exact names.

**Business hours use org local time** — Slot times are calculated using `DateTime.format()`, which respects the org's default timezone. If your business operates in a different timezone than the org setting, slots may appear offset.

**Person Account RecordType required** — `EA_AppointmentBooking` dynamically queries for any active PersonAccount RecordType. If Person Accounts are not enabled or no active RecordType exists, account creation will fail.

---

## Tweaking

| What to change | Where |
|---|---|
| Default search radius (50 mi) | `EA_LocationFinder` → `DEFAULT_RADIUS` |
| Max locations returned (3) | `EA_LocationFinder` → `top3.size() >= 3` |
| Slot duration (30 min) | `EA_SlotFinder` → `SLOT_DURATION_MINUTES` |
| Business hours start/end | `EA_SlotFinder` → `START_HOUR` / `END_HOUR` |
| Look-ahead window (60 days) | `EA_SlotFinder` → `windowEnd = windowStart.addDays(60)` |
| Number of slots returned (3) | `EA_SlotFinder` → `SLOTS_TO_RETURN` |
| Cancelled status values | `EA_SlotFinder` → `getBookedSlots()` Status NOT IN list |
