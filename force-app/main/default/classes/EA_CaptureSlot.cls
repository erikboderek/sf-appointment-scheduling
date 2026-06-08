/**
 * EA_CaptureSlot
 * Vibe-Coded by Erik Abderhalden
 *
 * Invocable Apex utility that resolves which slot the customer chose (1, 2, or 3)
 * and returns the corresponding start and end ISO timestamps. Intended to bridge
 * between EA_SlotFinder (which returns three candidate slots) and EA_AppointmentBooking
 * (which requires a single chosen start/end time).
 *
 * WHY THIS EXISTS
 *   Agentforce and Flow variables are typed — you cannot dynamically index into a set
 *   of numbered output fields based on a runtime integer. This class handles that
 *   indirection so the orchestration layer stays declarative.
 *
 * INPUTS (Request)
 *   choiceNumber    – Integer 1, 2, or 3 indicating which slot was selected.
 *   slot1StartISO / slot1EndISO – ISO timestamps from EA_SlotFinder output.
 *   slot2StartISO / slot2EndISO
 *   slot3StartISO / slot3EndISO
 *
 * OUTPUTS (Result)
 *   chosenStartISO  – Start time of the selected slot in ISO-8601 format.
 *   chosenEndISO    – End time of the selected slot in ISO-8601 format.
 *   isValid         – False if choiceNumber is not 1, 2, or 3.
 */
public with sharing class EA_CaptureSlot {

    public class Request {
        @InvocableVariable(label='Choice Number' description='1, 2, or 3 — which slot the customer picked' required=true)
        public Integer choiceNumber;
        @InvocableVariable(label='Slot 1 Start ISO' required=true)
        public String slot1StartISO;
        @InvocableVariable(label='Slot 1 End ISO' required=true)
        public String slot1EndISO;
        @InvocableVariable(label='Slot 2 Start ISO' required=true)
        public String slot2StartISO;
        @InvocableVariable(label='Slot 2 End ISO' required=true)
        public String slot2EndISO;
        @InvocableVariable(label='Slot 3 Start ISO' required=true)
        public String slot3StartISO;
        @InvocableVariable(label='Slot 3 End ISO' required=true)
        public String slot3EndISO;
    }

    public class Result {
        @InvocableVariable public String  chosenStartISO;
        @InvocableVariable public String  chosenEndISO;
        @InvocableVariable public Boolean isValid;
    }

    @InvocableMethod(label='Capture Chosen Slot' description='Resolves the start and end ISO times for the slot number the customer selected')
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            if (req.choiceNumber == 1) {
                res.chosenStartISO = req.slot1StartISO;
                res.chosenEndISO   = req.slot1EndISO;
                res.isValid = true;
            } else if (req.choiceNumber == 2) {
                res.chosenStartISO = req.slot2StartISO;
                res.chosenEndISO   = req.slot2EndISO;
                res.isValid = true;
            } else if (req.choiceNumber == 3) {
                res.chosenStartISO = req.slot3StartISO;
                res.chosenEndISO   = req.slot3EndISO;
                res.isValid = true;
            } else {
                res.isValid = false;
            }
            results.add(res);
        }
        return results;
    }
}
