import Foundation

// Representative document text for the smart-extraction tests. Every name,
// number and address here is fictional (the NT Logistics layout mirrors the
// legacy parser's regression fixture with personal details replaced).
enum SmartFixtures {

    /// Digital (text) PDF rate confirmation — clean labels, one stop each.
    static let textRateCon = """
        === PAGE 1 ===
        Summit Freight Brokerage, LLC
        4100 Commerce Blvd, Suite 200
        Dallas, TX 75201
        Phone: (214) 555-0199 ext 204    MC# 778812
        RATE CONFIRMATION
        Date: 09/15/2026
        Load #: SFB-448812          Confirmation #: 99812
        Reference #: REF-55120      PO #: 4500123321
        Carrier: Example Carrier LLC
        Driver Name: Test Driver
        Truck #: 2580    Trailer #: TV530209
        Equipment: 53' Dry Van
        Carrier Sales Rep: Maria Lopez
        Email: mlopez@summitfreight.com
        PICKUP 1
        Name: Riverbend Paper Mill
        1200 Industrial Pkwy
        Memphis, TN 38118
        Pickup Date: 09/17/2026   Appt: 08:00 - 10:00
        Pickup #: PU77120
        DELIVERY 1
        Name: Coastal Distribution Center
        88 Harbor Rd
        Savannah, GA 31408
        Delivery Date: 09/18/2026   Appt: 14:00
        Commodity: Paper Rolls
        Weight: 42,500 lbs
        Miles: 682
        Rate Details
        Line Haul ............ $2,600.00
        Fuel Surcharge ....... $250.00
        Total Carrier Pay .... $2,850.00
        Detention: $50.00/hr after 2 hours free
        TONU: $150.00 if cancelled after dispatch
        Carrier agrees to all terms and conditions of the broker carrier agreement on file, including payment terms, insurance requirements and tracking requirements for the duration of this load.
        """

    /// Scanned / OCR rate confirmation (NT Logistics layout, anonymized).
    static let scannedRateCon = """
        === OCR PAGE 1 ===
        Signature pages may contain page separators and partial words.
        tential
        clearly
        === OCR PAGE 2 ===
        NT LOGISTICS
        Rate Confirmation Agreement for NT Logistics Inc.
        This document can be used as a substitute for an invoice.
        Check calls must be made daily by 9 am EST or carrier will be charged a penalty fee of $100 per day.
        Driver is responsible for all load counts.
        Water loads Blue Triton PRIMO Statement
        Tracking Statement:
        Tracking on Trucker Tools is Required.
        For after hour issues that occur M-F 1800-0600 please call Amber @469-952-7672
        537902
        NT Logistics, Inc.
        Frisco, TX 75034
        7460 Warren Parkway, #301
        Phone: 469-362-5040
        Rate Confirmation
        Page 1
        0527290
        Carrier:
        EXAMPLE CARRIER LLC
        SPRINGFIELD IL 62701
        Date:
        06/03/2026
        Contact:
        Highway Rate Confirmation Delivery
        Phone:
        555-555-0142
        Factoring Co:
        TAFS - TRANSAM FINANCIAL SERVICES
        Order
        Order 0527290
        Miles:
        1462.0
        Commodity:
        Bentonite Minerals on Pallets
        Weight:
        43244.0
        BOL:
        clearly
        Trailer:
        Van (DAT)
        Reference:
        PU 1
        Name:
        PDS
        Address:
        105 W Sharp St
        Date:
        06/03/2026 0700
        06/03/2026 1600
        Contact:
        870-863-5707
        EL DORADO
        AR 71730
        SO 2 Name:
        Baroid Industrial Drilling Prod
        Date:
        06/05/2026 0800
        Address:
        789 Highway 14A East
        06/05/2026 1500
        LOVELL
        WY 82431
        Payment
        Carrier Freight Pay:
        $5,700.00
        Total Carrier Pay:
        $5,700.00
        Instructions
        PDS - STRAPS AND LOAD BARS REQUIRED
        For after-hours issues please call 469-952-7672
        For any questions, please call NT Logistics at 469-362-5040
        Operations@ntlogistics.com
        billing@ntlogistics.com
        quickpay@ntlogistics.com
        PO #
        tential
        Please Sign: Test
        Driver Name: Test Driver
        Driver Cell: 5555550100
        Driver Email: driver@example-carrier.com
        Tractor #: 2580
        Trailer #: TV530209
        Attention: Sahir Khan
        469-362-5000
        skhan@ntlogistics.com
        Highway Audit Report
        Rate Confirmation ID: 9359302
        Generated: June 03, 2026 13:36 UTC
        Activity History
        06/03/2026 13:36 UTC - Terms Accepted
        User: Tester (driver@example-carrier.com) - IP: 203.0.113.10
        06/03/2026 13:36 UTC - Viewed
        User: Tester (driver@example-carrier.com) - IP: 203.0.113.10
        06/03/2026 13:36 UTC - Delivered
        User: Sahir Khan (skhan@ntlogistics.com) - IP: N/A
        Digital signature audit trail for rate confirmation acceptance.
        """

    /// Multi-page: page 1 is legal terms, page 2 the load table, page 3 repeats a summary.
    static let multiPageRateCon = """
        === PAGE 1 ===
        BROKER-CARRIER TERMS AND CONDITIONS
        1. Carrier shall provide all equipment, labor and fuel necessary to transport the shipment described herein and shall comply with all applicable laws and regulations of the Department of Transportation.
        2. Payment will be made within thirty days of receipt of signed bill of lading and invoice. Quick pay is available for a fee of three percent of the total rate payable.
        3. Detention will be paid at $40.00 per hour after two hours free time when documented on the bill of lading and approved by the broker in writing.
        Page 1 of 3
        === PAGE 2 ===
        Great Plains Logistics Inc
        Load Tender / Rate Confirmation
        Load Number: GPL-20931
        Tender Date: 09/10/2026
        Shipper
        Prairie Grain Co-op
        450 Elevator Rd
        Salina, KS 67401
        Ready: 09/12/2026 0600-1400
        Consignee
        Front Range Foods
        7700 E 56th Ave
        Denver, CO 80216
        Deliver By: 09/13/2026 0800
        Commodity: Bagged Flour
        Weight: 44000 lb
        Linehaul: $1,450.00
        FSC: $210.50
        Lumper: $75.00
        Total: $1,735.50
        Page 2 of 3
        === PAGE 3 ===
        Great Plains Logistics Inc
        Load Summary GPL-20931
        Shipper
        Prairie Grain Co-op
        450 Elevator Rd
        Salina, KS 67401
        Consignee
        Front Range Foods
        7700 E 56th Ave
        Denver, CO 80216
        Page 3 of 3
        """

    /// Multi-stop load: two pickups, two deliveries, in order.
    static let multiStopRateCon = """
        Lakeshore Transport Solutions
        Carrier Rate Confirmation
        Order #: LTS-7781
        Stop 1 - Pickup
        Northside Plastics
        200 Polymer Dr
        Gary, IN 46406
        Date: 09/20/2026 07:00
        Stop 2 - Pickup
        Hoosier Packaging
        15 Box Factory Ln
        Elkhart, IN 46514
        Date: 09/20/2026 13:00
        Stop 3 - Delivery
        Midwest Retail DC
        9800 Logistics Way
        Columbus, OH 43217
        Date: 09/21/2026 06:00
        Stop 4 - Delivery
        Buckeye Grocers
        44 Market St
        Dayton, OH 45402
        Date: 09/21/2026 11:30
        Number of Stops: 4
        Commodity: Plastic Containers
        Weight: 18,200 LBS
        LH: $1,900.00
        Stop Off: $100.00
        Fuel Surcharge: $180.00
        Total Rate: $2,180.00
        """

    /// Low-quality OCR: dot leaders, "S" for "$", broken spacing, rate-per-mile noise.
    static let lowQualityRateCon = """
        FREIGHTWAY L0GISTICS LLC
        rate con
        LOAD N0 : FW 30912
        Load #: FW30912
        PU  1
        Tyson Plant
        Springdale , AR 72762
        09/22/26 05:00
        DEL 1
        Walmart DC 6054
        Bentonville, AR 72712
        09/22/26 16:00
        Rate per mile: $3.10
        Miles: 64
        Carrier Rate ....... S650.00
        """

    /// Rate con where the only number is a confirmation number and a date sits next to it.
    static let confirmationOnlyRateCon = """
        Apex Brokerage Inc
        Rate Confirmation
        Confirmation #: 5521009
        Printed: 09/01/2026
        Pickup: Joliet, IL
        Pickup Date: 09/03/2026
        Delivery: Toledo, OH
        Delivery Date: 09/04/2026
        Rate: $1,100.00
        """

    // MARK: Receipts

    static let lovesFuel = """
        LOVE'S TRAVEL STOP #356
        2501 S Grand St
        AMARILLO, TX 79103
        1-800-555-0142
        Pump 07
        TRUCK # 2580
        ODOMETER 412330
        DIESEL  125.482 GAL @ $3.899/GAL  $489.25
        DEF  4.250 GAL @ $2.799/GAL  $11.90
        SUBTOTAL  $501.15
        TAX  $0.00
        TOTAL DUE  $501.15
        VISA XXXX1234 AUTH 004521
        06/10/2026 14:32
        TRAN # 88213
        """

    static let messyPilotFuel = """
        Pilot Travel Center
        store #4421
        THANK YOU FOR YOUR BUSINESS
        DEISEL
        GAL 98.7
        $ / GAL 3.759
        SUBTOTAL 371.01
        TAX 0.00
        GRAND TOTAL $371.01
        REWARDS 8829301
        """

    static let fleetCardFuel = """
        FLYING J #714
        1100 N Service Rd
        Joplin, MO 64801
        Date: 09/14/2026  Time: 22:17
        Invoice: 0714-55213
        Unit: 12   Driver ID: 4471   Odometer: 381,244
        Product      Qty       Price     Amount
        ULSD         142.310   4.019     571.94
        DEF Bulk     6.500     3.299     21.44
        Total Sale                       593.38
        COMDATA  Card ************4421
        Auth Code: 776120
        """

    static let generalReceipt = """
        TRUCK STOP SUPPLY CO
        Store 118  (806) 555-0110
        501 Frontage Rd, Amarillo, TX 79118
        09/16/2026  3:41 PM
        Receipt #: 118-99021
        Ratchet Strap 2in x 27ft    2 @ 18.99    37.98
        Bungee Cord Set                          12.49
        Gloves Leather                           9.99
        Loyalty Discount                         -3.00
        Subtotal                                57.46
        Sales Tax 8.25%                          4.74
        Total                                   62.20
        Mastercard  ************8812   62.20
        Change Due                               0.00
        Rewards # 55512901233
        """

    static let tollReceipt = """
        Oklahoma Turnpike Authority
        Toll Plaza 12 - Will Rogers Turnpike
        09/11/2026 06:12
        Class 5 Axle
        Toll Amount $24.50
        PlatePay Account 00219
        """

    // MARK: Maintenance

    static let maintenanceInvoice = """
        === PAGE 1 ===
        Rush Truck Centers - Oklahoma City
        8700 W Reno Ave, Oklahoma City, OK 73127
        Phone (405) 555-0177
        SERVICE INVOICE
        Invoice #: 7718821        Repair Order #: RO-55102
        Invoice Date: 09/12/2026   Service Date: 09/11/2026
        Unit #: 2580   VIN: 1FUJHHDR0CLBP8834
        License Plate: AL 1234ABC
        Odometer: 412,105 mi   Engine Hours: 18,220
        Technician: J. Alvarez
        Complaint: PM service due. Oil leak at valve cover.
        Parts
        Part #       Description              Qty   Unit Price   Amount
        DF-12345     Fuel Filter                2       38.50      77.00
        LF-9001      Oil Filter                 1       34.99      34.99
        15W40-B      Engine Oil 15W-40         10       18.99     189.90
        VCG-2231     Valve Cover Gasket         1       64.25      64.25
        Parts Subtotal                                          366.14
        === PAGE 2 ===
        Rush Truck Centers - Invoice 7718821 (continued)
        Labor
        PM Service - Level A            1.5 hr x $145.00   $217.50
        Replace valve cover gasket      2.0 hr x $145.00   $290.00
        Labor Subtotal                                    $507.50
        Shop Supplies                                      $25.00
        Environmental Fee                                  $12.50
        Subtotal                                          $911.14
        Sales Tax                                          $30.21
        Invoice Total                                     $941.35
        Recommended: Replace front brake shoes within 5,000 miles.
        Next Service Due: 437,000 miles
        Page 2 of 2
        """

    static let tireInvoice = """
        Southern Tire Mart
        Store 44 - Birmingham, AL 35210
        Invoice No. 44-120983
        Date 09/05/2026
        Truck 2580  Mileage 409,880
        QTY  DESCRIPTION                          PRICE      TOTAL
        2    295/75R22.5 Drive Tire              389.00     778.00
        2    Mount and Balance                    25.00      50.00
        1    Scrap Tire Fee                        5.00       5.00
        Subtotal 833.00
        Tax 33.32
        Total Due 866.32
        """

    static let roadsideRepair = """
        Interstate Road Service LLC
        24/7 Roadside Assistance  (888) 555-0199
        Work Order # 30177
        Date of Service: 09/08/2026
        Location: I-40 MM 156, Amarillo, TX
        Truck 2580
        Service call / mobile repair
        Replace air line - labor 1 hr @ 165.00       165.00
        Service Call Fee                             150.00
        Parts: Air line fittings                      42.75
        Total                                        357.75
        """

    static let partsReceipt = """
        FleetPride #212
        3300 N Stemmons Fwy, Dallas, TX 75207
        Date: 09/09/2026
        Invoice 212-778120
        Part No.        Description            Qty    Price    Ext
        K-4122          Brake Chamber 30/30     1     58.40    58.40
        BW-8810         Slack Adjuster          2     42.15    84.30
        Subtotal 142.70
        Tax 11.77
        Total 154.47
        """

    static let ambiguousReceipt = """
        Thank you
        12.50
        09/03/2026
        14.00
        """
}
