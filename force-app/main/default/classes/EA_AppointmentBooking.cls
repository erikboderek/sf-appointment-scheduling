/**
 * EA_AppointmentBooking
 * Vibe-Coded by Erik Abderhalden
 *
 * Invocable Apex action that creates a ServiceAppointment for a customer. Intended
 * for use in Agentforce topics, Flows, or any invocable context.
 *
 * WHAT IT DOES
 *   1. Validates required inputs.
 *   2. Looks up an existing PersonAccount by mobile phone number, or creates one if
 *      none is found. Deduplication is phone-based to handle repeat customers.
 *   3. Inserts a ServiceAppointment linked to the account, territory, and work type.
 *   4. Returns the new appointment's system-assigned AppointmentNumber as a
 *      confirmation number for the customer.
 *
 * DEPENDENCIES
 *   - Person Accounts must be enabled in the org (Setup > Account Settings).
 *   - The org must have at least one active PersonAccount RecordType. The class
 *     queries for it dynamically — no hardcoded RecordType Id or name required.
 *   - ServiceTerritory and WorkType records must exist and be properly configured
 *     in Field Service settings.
 *
 * INPUTS (Request)
 *   scheduledStartISO  – Appointment start in ISO-8601 format (e.g. 2026-06-09T09:00:00).
 *   scheduledEndISO    – Appointment end in ISO-8601 format.
 *   workTypeId         – Id of the WorkType (from EA_SlotFinder output).
 *   territoryId        – Id of the ServiceTerritory (from EA_LocationFinder output).
 *   firstName          – Customer first name.
 *   lastName           – Customer last name.
 *   phone              – Customer phone number. Normalized to (###) ###-#### format.
 *   email              – Customer email (optional).
 *
 * OUTPUTS (Result)
 *   isSuccess          – True when the appointment was created.
 *   errorMessage       – Populated on failure.
 *   appointmentId      – Salesforce Id of the new ServiceAppointment.
 *   confirmationNumber – System-assigned AppointmentNumber (e.g. SA-00001234).
 */
public with sharing class EA_AppointmentBooking {

    public class Request {
        @InvocableVariable(label='Scheduled Start ISO' description='ISO-8601 start time e.g. 2026-06-09T09:00:00' required=true)
        public String scheduledStartISO;
        @InvocableVariable(label='Scheduled End ISO' description='ISO-8601 end time e.g. 2026-06-09T09:30:00' required=true)
        public String scheduledEndISO;
        @InvocableVariable(label='Work Type Id' required=true)
        public String workTypeId;
        @InvocableVariable(label='Territory Id' required=true)
        public String territoryId;
        @InvocableVariable(label='First Name' required=true)
        public String firstName;
        @InvocableVariable(label='Last Name' required=true)
        public String lastName;
        @InvocableVariable(label='Phone' required=true)
        public String phone;
        @InvocableVariable(label='Email')
        public String email;
    }

    public class Result {
        @InvocableVariable public Boolean isSuccess;
        @InvocableVariable public String  errorMessage;
        @InvocableVariable public String  appointmentId;
        @InvocableVariable public String  confirmationNumber;
    }

    @InvocableMethod(label='Book Appointment' description='Creates a ServiceAppointment for a customer at a chosen location and time slot')
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

        if (String.isBlank(req.firstName) || String.isBlank(req.lastName) || String.isBlank(req.phone)) {
            res.errorMessage = 'First name, last name, and phone are required.';
            return res;
        }

        try {
            DateTime scheduledStart = parseISO(req.scheduledStartISO);
            DateTime scheduledEnd   = parseISO(req.scheduledEndISO);

            // Find an existing PersonAccount matching this phone, or create a new one.
            // Using phone as the dedup key keeps repeat customers linked to one account.
            String accountId = findOrCreateAccount(req.firstName, req.lastName, req.phone, req.email);

            ServiceAppointment sa = new ServiceAppointment();
            sa.ParentRecordId     = accountId;
            sa.ServiceTerritoryId = sanitizeId(req.territoryId);
            sa.WorkTypeId         = sanitizeId(req.workTypeId);
            sa.SchedStartTime     = scheduledStart;
            sa.SchedEndTime       = scheduledEnd;
            sa.EarliestStartTime  = scheduledStart;
            sa.DueDate            = scheduledEnd;
            sa.Status             = 'Scheduled';
            sa.Subject            = req.firstName + ' ' + req.lastName + ' - Appointment';
            sa.Phone              = formatPhoneNumber(req.phone);
            if (String.isNotBlank(req.email)) {
                sa.Email = req.email;
            }

            insert sa;

            // Re-query after insert to get the system-assigned AppointmentNumber.
            sa = [SELECT Id, AppointmentNumber FROM ServiceAppointment WHERE Id = :sa.Id WITH USER_MODE LIMIT 1];
            res.appointmentId      = sa.Id;
            res.confirmationNumber = sa.AppointmentNumber;
            res.isSuccess          = true;

        } catch (Exception e) {
            res.errorMessage = 'Booking failed: ' + e.getMessage();
        }

        return res;
    }

    private static String findOrCreateAccount(String firstName, String lastName, String phone, String email) {
        String formattedPhone = formatPhoneNumber(phone);
        List<Account> existing = [
            SELECT Id FROM Account
            WHERE PersonMobilePhone = :formattedPhone
            WITH USER_MODE
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        Account acc = new Account();
        acc.FirstName         = firstName;
        acc.LastName          = lastName;
        acc.PersonMobilePhone = formattedPhone;
        acc.RecordTypeId      = getPersonAccountRecordTypeId();
        if (String.isNotBlank(email)) {
            acc.PersonEmail = email;
        }
        insert acc;
        return acc.Id;
    }

    /**
     * Queries for any active PersonAccount RecordType dynamically.
     * No RecordType name or Id is hardcoded — works across orgs as long as
     * Person Accounts are enabled and at least one PersonAccount RecordType is active.
     */
    private static Id getPersonAccountRecordTypeId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND IsPersonType = true AND IsActive = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (!rts.isEmpty()) {
            return rts[0].Id;
        }
        return null;
    }

    /**
     * DateTime.valueOf() requires a space between date and time ("yyyy-MM-dd HH:mm:ss").
     * ISO-8601 strings use 'T' as the separator, so we replace it before parsing.
     */
    private static DateTime parseISO(String isoString) {
        if (String.isBlank(isoString)) {
            throw new IllegalArgumentException('ISO date string is required.');
        }
        return DateTime.valueOf(isoString.replace('T', ' '));
    }

    /** Normalizes a phone number to (###) ###-#### format. Strips non-digits and handles country code 1. */
    private static String formatPhoneNumber(String phone) {
        if (String.isBlank(phone)) return phone;
        String digits = phone.replaceAll('[^0-9]', '');
        if (digits.length() == 11 && digits.startsWith('1')) {
            digits = digits.substring(1);
        }
        if (digits.length() == 10) {
            return '(' + digits.substring(0, 3) + ') ' + digits.substring(3, 6) + '-' + digits.substring(6);
        }
        return phone;
    }

    /**
     * Validates that the string looks like a 15- or 18-character Salesforce ID.
     * Prevents booking failures caused by an LLM passing a descriptive string
     * (e.g. "the territory in Sacramento") instead of an actual record Id.
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
