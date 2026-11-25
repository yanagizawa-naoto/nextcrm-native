import { Body, Container, Head, Heading, Hr, Html, Preview, Text } from "@react-email/components";

type ScheduledReportProps = { reportName: string; dateRange: string };

export default function ScheduledReport({ reportName = "Report", dateRange = "" }: ScheduledReportProps) {
  return (
    <Html>
      <Head />
      <Preview>{"定期配信レポート："}{reportName}</Preview>
      <Body style={{ fontFamily: "sans-serif", padding: "20px" }}>
        <Container>
          <Heading as="h2">{reportName}</Heading>
          {dateRange && <Text style={{ color: "#666" }}>{"対象期間："}{dateRange}</Text>}
          <Hr />
          <Text>{"このメールにレポートを添付しています。"}</Text>
          <Text style={{ color: "#999", fontSize: "12px" }}>{"このメールはNextCRMから自動送信されています。"}</Text>
        </Container>
      </Body>
    </Html>
  );
}
