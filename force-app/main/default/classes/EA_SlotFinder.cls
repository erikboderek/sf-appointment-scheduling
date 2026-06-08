/**
 * EA_SlotFinder
 * Vibe-Coded by Erik Abderhalden
 *
 * Invocable Apex action that returns the next 3 available 30-minute appointment slots
 * for a given Service Territory and Work Type. Intended for use in Agentforce topics,
 * Flows, or any invocable context.
 *
 * HOW SLOT FINDING WORKS
 *   Starting from the current date/time, the class walks forward minute-by-minute
 *   (in 30-min increments) looking for slots that are:
 *     • On a weekday (Monday–Friday)
 *     • Within business hours (START_HOUR–END_HOUR, using org local time via DateTime.format())
 *     • Not already occupied by an existing non-cancelled ServiceAppointment
 *   The first 3 qualifying slots are returned.
 *
 * CONFIGURATION
 *   SLOT_DURATION_MINUTES  – Length of each appointment. Default: 30.
 *   START_HOUR             – Business day start (local time, 24-hr). Default: 9.
 *   END_HOUR               – Business day end (local time, 24-hr). Default: 17 (5 PM).
 *   SLOTS_TO_RETURN        – How many slots to return. Default: 3.
 *   windowEnd              – How far ahead to search. Default: 60 days from now.
 *   To change business hours or timezone behavior, update these constants or adapt
 *   the cursor logic to use a specific TimeZone with DateTime.format(pattern, tz).
 *
 * INPUTS (Request)
 *   territoryId   – Id of the ServiceTerritory to search.
 *   workTypeName  – Name of the WorkType (must match exactly, case-sensitive).
 *
 * OUTPUTS (Result)
 *   isSuccess         – True when at least one slot was found.
 *   errorMessage      – Populated on failure or when no slots are available.
 *   workTypeId        – Resolved Id of the WorkType (useful for downstream booking).
 *   slot1Label/StartISO/EndISO – Human-readable label and ISO timestamps for slot 1.
 *   slot2…, slot3…   – Same for the 2nd and 3rd slots.
 *
 * DEPENDENCIES
 *   ServiceAppointment records for the territory are queried to detect conflicts.
 *   Status values 'Canceled' and 'Cannot Complete' are treated as available.
 *   Adjust the exclusion list in getBookedSlots() to match your org's status picklist.
 */
public with sharing class EA_SlotFinder {

    public class Request {
        @InvocableVariable(label='Territory Id' description='Service Territory SF ID' required=true)
        public String territoryId;
        @InvocableVariable(label='Work Type Name' description='Name of the selected work type / service' required=true)
        public String workTypeName;
    }

    public class Result {
        @InvocableVariable public String  slot1Label;
        @InvocableVariable public String  slot1StartISO;
        @InvocableVariable public String  slot1EndISO;
        @InvocableVariable public String  slot2Label;
        @InvocableVariable public String  slot2StartISO;
        @InvocableVariable public String  slot2EndISO;
        @InvocableVariable public String  slot3Label;
        @InvocableVariable public String  slot3StartISO;
        @InvocableVariable public String  slot3EndISO;
        @InvocableVariable public String  workTypeId;
        @InvocableVariable public Boolean isSuccess;
        @InvocableVariable public String  errorMessage;
    }

    private static final Integer SLOT_DURATION_MINUTES = 30;
    private static final Integer START_HOUR = 9;
    private static final Integer END_HOUR   = 17;
    private static final Integer SLOTS_TO_RETURN = 3;

    @InvocableMethod(label='Find Available Appointment Slots' description='Returns the next 3 available appointment time slots for a Service Territory and Work Type')
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(processRequest(req));
        }
        return results;
    }

    private static Result processRequest(Request req) {
        Result res = new Result();
        res.isSuccess = false;

        if (String.isBlank(req.territoryId) || String.isBlank(req.workTypeName)) {
            res.errorMessage = 'Territory ID and work type name are required.';
            return res;
        }

        try {
            // Resolve the WorkType by name so we can return its Id to the caller.
            List<WorkType> workTypes = [
                SELECT Id FROM WorkType
                WHERE Name = :req.workTypeName
                WITH USER_MODE
                LIMIT 1
            ];
            if (workTypes.isEmpty()) {
                res.errorMessage = 'Work type "' + req.workTypeName + '" not found.';
                return res;
            }
            res.workTypeId = workTypes[0].Id;

            // Pre-load all booked slot start times in the search window to enable fast
            // O(1) conflict checks as we walk through candidate slots.
            DateTime windowStart = DateTime.now();
            DateTime windowEnd   = windowStart.addDays(60);
            Set<String> bookedSlots = getBookedSlots(req.territoryId, windowStart, windowEnd);

            DateTime cursor = DateTime.now();
            Integer found = 0;

            while (found < SLOTS_TO_RETURN && cursor < windowEnd) {
                // DateTime.format() returns the value in the org's local timezone, so
                // START_HOUR/END_HOUR comparisons respect local business hours correctly.
                Date    d        = Date.valueOf(cursor.format('yyyy-MM-dd'));
                Integer localHr  = Integer.valueOf(cursor.format('H'));
                Integer localMin = Integer.valueOf(cursor.format('m'));

                // Skip Saturday (6) and Sunday (0)
                Integer dow = getDayOfWeek(d);
                if (dow == 0 || dow == 6) {
                    cursor = DateTime.newInstance(d.addDays(1), Time.newInstance(START_HOUR, 0, 0, 0));
                    continue;
                }

                // Advance to start of business if we're before opening time
                if (localHr < START_HOUR) {
                    cursor = DateTime.newInstance(d, Time.newInstance(START_HOUR, 0, 0, 0));
                    continue;
                }

                // Roll to the next business day if we've reached or passed closing time
                if (localHr >= END_HOUR) {
                    cursor = DateTime.newInstance(d.addDays(1), Time.newInstance(START_HOUR, 0, 0, 0));
                    continue;
                }

                // Round up to the next 30-minute boundary (e.g. 9:07 → 9:30)
                Integer minutesMod = Math.mod(localMin, SLOT_DURATION_MINUTES);
                if (minutesMod != 0) {
                    cursor  = cursor.addMinutes(SLOT_DURATION_MINUTES - minutesMod);
                    localHr = Integer.valueOf(cursor.format('H'));
                }

                // After rounding, re-check that the slot still starts before closing
                if (localHr >= END_HOUR) {
                    cursor = DateTime.newInstance(d.addDays(1), Time.newInstance(START_HOUR, 0, 0, 0));
                    continue;
                }

                DateTime slotEnd = cursor.addMinutes(SLOT_DURATION_MINUTES);
                String isoStart  = formatISO(cursor);

                if (!bookedSlots.contains(isoStart)) {
                    String lbl    = formatLabel(cursor);
                    String endISO = formatISO(slotEnd);
                    if (found == 0) {
                        res.slot1Label    = lbl;
                        res.slot1StartISO = isoStart;
                        res.slot1EndISO   = endISO;
                    } else if (found == 1) {
                        res.slot2Label    = lbl;
                        res.slot2StartISO = isoStart;
                        res.slot2EndISO   = endISO;
                    } else {
                        res.slot3Label    = lbl;
                        res.slot3StartISO = isoStart;
                        res.slot3EndISO   = endISO;
                    }
                    found++;
                }

                cursor = cursor.addMinutes(SLOT_DURATION_MINUTES);
            }

            if (res.slot1Label == null) {
                res.errorMessage = 'No available slots found in the next 60 days for this location.';
                return res;
            }

            res.isSuccess = true;
        } catch (Exception e) {
            res.errorMessage = 'Error finding slots: ' + e.getMessage();
        }

        return res;
    }

    /**
     * Queries existing ServiceAppointments for the territory within the window and
     * returns their start times as ISO strings. Used to skip already-booked slots.
     * Adjust the Status exclusion list to match your org's appointment status picklist.
     */
    private static Set<String> getBookedSlots(String territoryId, DateTime windowStart, DateTime windowEnd) {
        Set<String> booked = new Set<String>();
        List<ServiceAppointment> appts = [
            SELECT SchedStartTime FROM ServiceAppointment
            WHERE ServiceTerritoryId = :territoryId
              AND SchedStartTime >= :windowStart
              AND SchedStartTime <= :windowEnd
              AND Status NOT IN ('Canceled', 'Cannot Complete')
            WITH USER_MODE
            LIMIT 1000
        ];
        for (ServiceAppointment sa : appts) {
            booked.add(formatISO(sa.SchedStartTime));
        }
        return booked;
    }

    /** Returns a UTC ISO-8601 string without timezone offset (matches how slots are stored). */
    private static String formatISO(DateTime dt) {
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss');
    }

    /** Returns a human-readable label like "Monday, June 9 at 9:00 AM". */
    private static String formatLabel(DateTime dt) {
        String dayName  = dt.format('EEEE');
        String monthDay = dt.format('MMMM d');
        String timeStr  = dt.format('h:mm a');
        return dayName + ', ' + monthDay + ' at ' + timeStr;
    }

    /**
     * Calculates day of week (0=Sunday … 6=Saturday) without using Date.daysBetween()
     * directly. Uses January 1, 2006 (a known Sunday) as a fixed epoch and takes the
     * modulo of the day offset — avoids needing a Datetime instance or timezone lookup.
     */
    private static Integer getDayOfWeek(Date d) {
        Date epoch = Date.newInstance(2006, 1, 1); // Sunday
        return Math.mod(epoch.daysBetween(d), 7);
    }
}
