/**
 * EA_AppointmentReschedule
 * Vibe-Coded by Erik Abderhalden
 *
 * Invocable Apex action that looks up or reschedules an existing ServiceAppointment
 * by confirmation number (AppointmentNumber). Intended for use in Agentforce topics,
 * Flows, or any invocable context.
 *
 * TWO MODES
 *   Lookup only  – Pass confirmationNumber; leave newSlotISO blank.
 *                  Returns current appointment details without modifying anything.
 *   Reschedule   – Pass confirmationNumber + newSlotISO + newSlotEndISO.
 *                  Updates SchedStartTime, SchedEndTime, EarliestStartTime, DueDate.
 *                  Optionally updates ServiceTerritoryId if newTerritoryId is provided.
 *
 * INPUTS (Request)
 *   confirmationNumber – The AppointmentNumber assigned at booking (e.g. SA-00001234).
 *   newSlotISO         – ISO-8601 start time for the new slot. Blank = lookup only.
 *   newSlotEndISO      – ISO-8601 end time for the new slot. Required when rescheduling.
 *   newTerritoryId     – Id of the new ServiceTerritory. Optional; omit to keep current location.
 *
 * OUTPUTS (Result)
 *   isSuccess              – True on successful lookup or reschedule.
 *   errorMessage           – Populated when the appointment is not found or an error occurs.
 *   appointmentId          – Salesforce Id of the ServiceAppointment.
 *   currentStartFormatted  – Human-readable current start time (e.g. "Monday, June 9 at 9:00 AM").
 *   currentTerritoryId     – Id of the current ServiceTerritory.
 *   currentTerritoryName   – Name of the current ServiceTerritory.
 *   currentWorkTypeName    – Name of the WorkType on the appointment.
 *   newStartFormatted      – Human-readable new start time. Populated only when wasUpdated = true.
 *   wasUpdated             – True when the appointment was actually rescheduled.
 */
public with sharing class EA_AppointmentReschedule {

    public class Request {
        @InvocableVariable(label='Confirmation Number' description='The AppointmentNumber from the original booking e.g. SA-00001234' required=true)
        public String confirmationNumber;
        @InvocableVariable(label='New Slot ISO' description='ISO-8601 new start time. Leave blank to look up current appointment only.')
        public String newSlotISO;
        @InvocableVariable(label='New Slot End ISO' description='ISO-8601 new end time. Required when new slot is provided.')
        public String newSlotEndISO;
        @InvocableVariable(label='New Territory Id' description='Service Territory ID for new location. Leave blank to keep current location.')
        public String newTerritoryId;
    }

    public class Result {
        @InvocableVariable public Boolean isSuccess;
        @InvocableVariable public String  errorMessage;
        @InvocableVariable public String  appointmentId;
        @InvocableVariable public String  currentStartFormatted;
        @InvocableVariable public String  currentTerritoryId;
        @InvocableVariable public String  currentTerritoryName;
        @InvocableVariable public String  currentWorkTypeName;
        @InvocableVariable public String  newStartFormatted;
        @InvocableVariable public Boolean wasUpdated;
    }

    @InvocableMethod(label='Look Up or Reschedule Appointment' description='Looks up or reschedules an existing appointment by confirmation number')
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(processRequest(req));
        }
        return results;
    }

    private static Result processRequest(Request req) {
        Result res = new Result();
        res.isSuccess  = false;
        res.wasUpdated = false;

        if (String.isBlank(req.confirmationNumber)) {
            res.errorMessage = 'Confirmation number is required.';
            return res;
        }

        try {
            List<ServiceAppointment> appts = [
                SELECT Id, AppointmentNumber, SchedStartTime, SchedEndTime,
                       ServiceTerritoryId, ServiceTerritory.Name,
                       WorkTypeId, WorkType.Name, Status
                FROM ServiceAppointment
                WHERE AppointmentNumber = :req.confirmationNumber.trim()
                WITH USER_MODE
                LIMIT 1
            ];

            if (appts.isEmpty()) {
                res.errorMessage = 'No appointment found for confirmation number "' + req.confirmationNumber + '".';
                return res;
            }

            ServiceAppointment sa = appts[0];
            res.appointmentId         = sa.Id;
            res.currentStartFormatted = formatDateTime(sa.SchedStartTime);
            res.currentTerritoryId    = sa.ServiceTerritoryId;
            res.currentTerritoryName  = sa.ServiceTerritory != null ? sa.ServiceTerritory.Name : '';
            res.currentWorkTypeName   = sa.WorkType != null ? sa.WorkType.Name : '';

            // Lookup-only mode — no new slot provided, return current details
            if (String.isBlank(req.newSlotISO)) {
                res.isSuccess = true;
                return res;
            }

            // Reschedule mode
            if (String.isBlank(req.newSlotEndISO)) {
                res.errorMessage = 'New slot end time is required when rescheduling.';
                return res;
            }

            sa.SchedStartTime    = parseISO(req.newSlotISO);
            sa.SchedEndTime      = parseISO(req.newSlotEndISO);
            sa.EarliestStartTime = sa.SchedStartTime;
            sa.DueDate           = sa.SchedEndTime;

            // Only update the territory if a new one was explicitly provided
            if (String.isNotBlank(req.newTerritoryId)) {
                sa.ServiceTerritoryId = sanitizeId(req.newTerritoryId);
            }

            update sa;

            res.newStartFormatted = formatDateTime(sa.SchedStartTime);
            res.wasUpdated = true;
            res.isSuccess  = true;

        } catch (Exception e) {
            res.errorMessage = 'Reschedule error: ' + e.getMessage();
        }

        return res;
    }

    /**
     * DateTime.valueOf() requires a space between date and time ("yyyy-MM-dd HH:mm:ss").
     * ISO-8601 strings use 'T' as the separator, so we replace it before parsing.
     */
    private static DateTime parseISO(String isoString) {
        return DateTime.valueOf(isoString.replace('T', ' '));
    }

    /** Returns a human-readable label like "Monday, June 9 at 9:00 AM". */
    private static String formatDateTime(DateTime dt) {
        if (dt == null) return '';
        String dayName  = dt.format('EEEE');
        String monthDay = dt.format('MMMM d');
        String timeStr  = dt.format('h:mm a');
        return dayName + ', ' + monthDay + ' at ' + timeStr;
    }

    /**
     * Validates that the string looks like a 15- or 18-character Salesforce ID.
     * Prevents failures caused by an LLM passing a descriptive string instead of
     * an actual record Id.
     */
    private static String sanitizeId(String idStr) {
        if (String.isBlank(idStr)) return idStr;
        String trimmed = idStr.trim();
        if (trimmed.length() == 15 || trimmed.length() == 18) {
            return trimmed;
        }
        throw new IllegalArgumentException('Invalid Salesforce ID: ' + idStr);
    }
}
