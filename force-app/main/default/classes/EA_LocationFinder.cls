/**
 * EA_LocationFinder
 * Vibe-Coded by Erik Abderhalden
 *
 * Invocable Apex action that finds up to 3 active Service Territories near a given
 * location (street address, city, state, or ZIP code). Intended for use in Agentforce
 * topics, Flows, or any invocable context.
 *
 * DEPENDENCIES
 *   - Salesforce Maps managed package (maps.API) must be installed in the org for
 *     geocoding to work. If it is not installed, the class falls back gracefully by
 *     returning all active territories sorted alphabetically with no distance filter.
 *   - ServiceTerritory records must be active and have Latitude/Longitude populated.
 *     Set these on the territory record or use Salesforce Maps territory setup.
 *
 * INPUTS (Request)
 *   locationInput  – Any address string: street, city, state, ZIP, or combination.
 *                    Passed directly to maps.API.Geocode(), which handles all formats.
 *   radiusMiles    – Optional. Search radius in miles. Defaults to 50.
 *
 * OUTPUTS (Result)
 *   isSuccess      – True when at least one location was found.
 *   errorMessage   – Populated on failure.
 *   locationCount  – Number of locations returned (1–3).
 *   loc1Id/Name/Address/Distance – Details for the closest location.
 *   loc2…, loc3…  – Details for the 2nd and 3rd closest (if present).
 *
 * GEOGRAPHIC SCOPE
 *   No hard geographic boundary is enforced. Results are limited to active
 *   ServiceTerritory records that fall within radiusMiles of the geocoded input.
 *   Expanding/narrowing the radius (or adjusting the default) controls coverage.
 */
public with sharing class EA_LocationFinder {

    public class Request {
        @InvocableVariable(label='Location Input' description='Street address, city, state, or ZIP code' required=true)
        public String locationInput;
        @InvocableVariable(label='Radius Miles' description='Search radius in miles; defaults to 50')
        public Integer radiusMiles;
    }

    public class Result {
        @InvocableVariable public Boolean isSuccess;
        @InvocableVariable public String  errorMessage;
        @InvocableVariable public Integer locationCount;
        @InvocableVariable public String  loc1Id;
        @InvocableVariable public String  loc1Name;
        @InvocableVariable public String  loc1Address;
        @InvocableVariable public String  loc1Distance;
        @InvocableVariable public String  loc2Id;
        @InvocableVariable public String  loc2Name;
        @InvocableVariable public String  loc2Address;
        @InvocableVariable public String  loc2Distance;
        @InvocableVariable public String  loc3Id;
        @InvocableVariable public String  loc3Name;
        @InvocableVariable public String  loc3Address;
        @InvocableVariable public String  loc3Distance;
    }

    private static final Integer DEFAULT_RADIUS = 50;

    @InvocableMethod(label='Find Nearby Locations' description='Find up to 3 Service Territory locations near a street address, city, or ZIP code using Salesforce Maps geocoding')
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

        if (String.isBlank(req.locationInput)) {
            res.errorMessage = 'Location input is required.';
            return res;
        }

        Integer radius = (req.radiusMiles != null && req.radiusMiles > 0) ? req.radiusMiles : DEFAULT_RADIUS;

        try {
            Decimal customerLat = null;
            Decimal customerLng = null;

            // Geocode the input using Salesforce Maps.
            // Requires the Salesforce Maps managed package. If unavailable, the catch
            // block below silently skips geocoding and all active territories are returned.
            Map<String, Object> geocodeOptions = new Map<String, Object>{
                'version' => '1',
                'address' => req.locationInput.trim()
            };

            try {
                Map<String, Object> geocodeResponse = maps.API.Geocode(geocodeOptions);
                Boolean geocodeSuccess = (Boolean) geocodeResponse.get('success');
                if (geocodeSuccess) {
                    Map<String, Object> data     = (Map<String, Object>) geocodeResponse.get('data');
                    Map<String, Object> position = (Map<String, Object>) data.get('position');
                    customerLat = (Decimal) position.get('lat');
                    customerLng = (Decimal) position.get('lng');
                }
            } catch (Exception geocodeEx) {
                // Geocoding unavailable — fall back to listing all active territories
            }

            // Query all active territories that have coordinates set.
            // Territories missing lat/lng are excluded because distance cannot be calculated.
            List<ServiceTerritory> territories = [
                SELECT Id, Name, Street, City, State, PostalCode, Latitude, Longitude
                FROM ServiceTerritory
                WHERE IsActive = true
                  AND Latitude != null
                  AND Longitude != null
                WITH USER_MODE
                ORDER BY Name
                LIMIT 100
            ];

            List<TerritoryDistance> candidates = new List<TerritoryDistance>();
            for (ServiceTerritory st : territories) {
                Decimal dist = (customerLat != null)
                    ? haversineMiles(customerLat, customerLng, st.Latitude, st.Longitude)
                    : null;

                // When geocoding succeeded, skip territories outside the radius.
                // When geocoding failed (dist == null), include everything.
                if (customerLat != null && dist > radius) continue;

                TerritoryDistance td = new TerritoryDistance();
                td.territory     = st;
                td.distanceMiles = dist;
                candidates.add(td);
            }

            if (customerLat != null) {
                candidates.sort();
            }

            List<TerritoryDistance> top3 = new List<TerritoryDistance>();
            for (TerritoryDistance td : candidates) {
                if (top3.size() >= 3) break;
                top3.add(td);
            }

            if (top3.isEmpty()) {
                res.errorMessage = 'No locations found near "' + req.locationInput + '". Try a different city or ZIP code.';
                return res;
            }

            res.locationCount = top3.size();
            for (Integer i = 0; i < top3.size(); i++) {
                TerritoryDistance td = top3[i];
                ServiceTerritory  st = td.territory;
                String addr = buildAddress(st);
                String dist = td.distanceMiles != null
                    ? td.distanceMiles.setScale(1).toPlainString() + ' mi'
                    : '';
                if (i == 0) { res.loc1Id = st.Id; res.loc1Name = st.Name; res.loc1Address = addr; res.loc1Distance = dist; }
                if (i == 1) { res.loc2Id = st.Id; res.loc2Name = st.Name; res.loc2Address = addr; res.loc2Distance = dist; }
                if (i == 2) { res.loc3Id = st.Id; res.loc3Name = st.Name; res.loc3Address = addr; res.loc3Distance = dist; }
            }

            res.isSuccess = true;
        } catch (Exception e) {
            res.errorMessage = 'Error finding locations: ' + e.getMessage();
        }

        return res;
    }

    private static String buildAddress(ServiceTerritory st) {
        String addr = '';
        if (String.isNotBlank(st.Street))     addr += st.Street + ', ';
        if (String.isNotBlank(st.City))       addr += st.City + ', ';
        if (String.isNotBlank(st.State))      addr += st.State + ' ';
        if (String.isNotBlank(st.PostalCode)) addr += st.PostalCode;
        return addr.trim().removeEnd(',');
    }

    /**
     * Haversine formula: calculates the great-circle distance in miles between
     * two lat/lng points. Accuracy is sufficient for city-level proximity matching.
     */
    private static Decimal haversineMiles(Decimal lat1, Decimal lng1, Decimal lat2, Decimal lng2) {
        Decimal r = 3958.8; // Earth's mean radius in miles
        Decimal dLat = (lat2 - lat1) * Math.PI / 180;
        Decimal dLng = (lng2 - lng1) * Math.PI / 180;
        Double a = Math.sin(dLat.doubleValue() / 2) * Math.sin(dLat.doubleValue() / 2)
                 + Math.cos(lat1.doubleValue() * Math.PI / 180) * Math.cos(lat2.doubleValue() * Math.PI / 180)
                 * Math.sin(dLng.doubleValue() / 2) * Math.sin(dLng.doubleValue() / 2);
        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return Decimal.valueOf(r.doubleValue() * c);
    }

    /** Wrapper used to sort territories by distance ascending. */
    private class TerritoryDistance implements Comparable {
        public ServiceTerritory territory;
        public Decimal distanceMiles;
        public Integer compareTo(Object other) {
            TerritoryDistance o = (TerritoryDistance) other;
            if (this.distanceMiles == null && o.distanceMiles == null) return 0;
            if (this.distanceMiles == null) return  1;
            if (o.distanceMiles    == null) return -1;
            if (this.distanceMiles < o.distanceMiles) return -1;
            if (this.distanceMiles > o.distanceMiles) return  1;
            return 0;
        }
    }
}
