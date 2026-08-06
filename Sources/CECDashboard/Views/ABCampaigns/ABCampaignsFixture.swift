import SwiftUI

// Frozen fixture for the Campaigns drill-down preview harness — no network,
// deterministic dates, renders the REAL views (root scaffold included) at each
// drill level. Mirrors ABLeadsFixture's role for the Leads tab.

@MainActor
enum ABCampaignsFixture {
    static let inputs = CampaignInputs(
        summaries: [
            CampaignSummary(id: "fx-c1", name: "Veterinary Clinics TX — AI Receptionist",
                            status: "active",
                            leadStatusCounts: ["pending": 18, "sent": 61, "replied": 6, "bounced": 2],
                            totalLeads: 87, totalSent: 143, totalReplies: 6),
            CampaignSummary(id: "fx-c2", name: "EV Dealers CA — Conversational AI",
                            status: "paused",
                            leadStatusCounts: ["pending": 40, "sent": 12],
                            totalLeads: 52, totalSent: 12, totalReplies: 0),
            CampaignSummary(id: "fx-c3", name: "Residential Solar AZ — Speed-to-Lead",
                            status: "completed",
                            leadStatusCounts: ["sent": 88, "replied": 9, "unsubscribed": 3, "held": 2],
                            totalLeads: 102, totalSent: 260, totalReplies: 9),
        ],
        partial: false)

    static let roster: [CampaignRosterEntry] = [
        CampaignRosterEntry(leadId: "fx-l1", status: "replied",
                            addedAt: "2026-06-02T09:00:00+00:00",
                            companyName: "Quillfeather Veterinary", email: "frontdesk@quillfeathervet.example"),
        CampaignRosterEntry(leadId: "fx-l2", status: "sent",
                            addedAt: "2026-06-02T09:00:00+00:00",
                            companyName: "Marrowind Animal Hospital", email: "hello@marrowindanimal.example"),
        CampaignRosterEntry(leadId: "fx-l3", status: "pending",
                            addedAt: "2026-06-03T14:30:00+00:00",
                            companyName: nil, email: "clinic@pawsquill.example"),
        CampaignRosterEntry(leadId: "fx-l4", status: "bounced",
                            addedAt: "2026-06-03T14:30:00+00:00",
                            companyName: "Tansyvale Pet Care", email: "care@tansyvalepets.example"),
    ]

    static let threadItems: [CorrespondenceItem] = [
        CorrespondenceItem(
            id: "int-1", kind: .interaction, queueId: nil, direction: "outbound",
            queueStatus: nil, subject: "quick question about your front desk",
            body: "Hey Dana,\n\nSaw Quillfeather Vet's reviews mention hold times at the front desk. We build AI receptionists for clinics — books appointments, answers after-hours calls.\n\nWorth a 10-minute look?\n\n— Adrian",
            bodyUnreadable: false, stepNumber: 1, variantIndex: 0,
            sendingAccount: "adrian@atlasautomates.com", toEmail: nil, error: nil,
            date: DateParse.iso("2026-06-05T15:04:00+00:00"),
            timestamp: "2026-06-05T15:04:00+00:00", fromOtherCampaign: false),
        CorrespondenceItem(
            id: "int-2", kind: .interaction, queueId: nil, direction: "inbound",
            queueStatus: nil, subject: "Re: quick question about your front desk",
            body: "Hi Adrian — timely, we just lost our evening receptionist. What does setup look like and what does it cost?\n\nDana",
            bodyUnreadable: false, stepNumber: nil, variantIndex: nil,
            sendingAccount: nil, toEmail: nil, error: nil,
            date: DateParse.iso("2026-06-06T02:11:00+00:00"),
            timestamp: "2026-06-06T02:11:00+00:00", fromOtherCampaign: false),
        CorrespondenceItem(
            id: "sq-fx-1", kind: .queued, queueId: "fx-1", direction: nil,
            queueStatus: "failed", subject: nil, body: nil,
            bodyUnreadable: true, stepNumber: 2, variantIndex: nil,
            sendingAccount: "adrian@atlasautomates.com",
            toEmail: "frontdesk@quillfeathervet.example", error: "SMTP 421 — retry scheduled",
            date: DateParse.iso("2026-06-09T16:00:00+00:00"),
            timestamp: "2026-06-09T16:00:00+00:00", fromOtherCampaign: false),
        CorrespondenceItem(
            id: "sq-fx-2", kind: .queued, queueId: "fx-2", direction: nil,
            queueStatus: "pending",
            subject: "following up — evening coverage",
            body: "{{greetingLine}}\n\nCircling back on the evening coverage gap — happy to show the receptionist handling a live booking call.\n\n— {{sendingAccountFirstName}}",
            bodyUnreadable: false, stepNumber: 3, variantIndex: nil,
            sendingAccount: "adrian@atlasautomates.com",
            toEmail: "frontdesk@quillfeathervet.example", error: nil,
            date: DateParse.iso("2026-06-12T16:00:00+00:00"),
            timestamp: "2026-06-12T16:00:00+00:00", fromOtherCampaign: false),
    ]

    /// Level 1 — the campaign list.
    static func list() -> some View {
        ABCampaignsView(inputs: inputs, drill: CampaignDrillModel(), staticRender: true)
    }

    /// Level 2 — one campaign's leads.
    static func leads() -> some View {
        ABCampaignsView(
            inputs: inputs,
            drill: CampaignDrillModel(fixtureCampaign: inputs.summaries[0], roster: roster),
            staticRender: true)
    }

    /// Level 3 — the correspondence timeline (staged card revised + editable).
    static func thread() -> some View {
        ABCampaignsView(
            inputs: inputs,
            drill: CampaignDrillModel(fixtureCampaign: inputs.summaries[0], roster: roster,
                                      lead: roster[0], thread: threadItems),
            staticRender: true)
    }

    /// Level 3 with the revision editor OPEN on the staged card — stills the
    /// app's only write affordance, and routes the TextEditor's isStaticRender
    /// gate through the placeholder detector (platform review).
    static func threadEditing() -> some View {
        let drill = CampaignDrillModel(fixtureCampaign: inputs.summaries[0], roster: roster,
                                       lead: roster[0], thread: threadItems)
        return ABCorrespondenceView(campaign: inputs.summaries[0], lead: roster[0],
                                    drill: drill, staticRender: true,
                                    fixtureEditingId: "sq-fx-2")
            .padding(DesignTokens.space6)
            .background(DesignTokens.bgRoot)
            .preferredColorScheme(.dark)
    }
}
