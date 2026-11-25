import {
  Body,
  Button,
  Container,
  Column,
  Head,
  Heading,
  Hr,
  Html,
  Img,
  Link,
  Preview,
  Row,
  Section,
  Tailwind,
  Text,
} from "@react-email/components";
import * as React from "react";

interface VercelInviteUserEmailProps {
  username: string;
  invitedByUsername: string;
  userLanguage: string;
}

const baseUrl = process.env.NEXT_PUBLIC_APP_URL;

export const InviteUserEmail = ({
  username,
  invitedByUsername,
  userLanguage,
}: VercelInviteUserEmailProps) => {
  const previewText =
    userLanguage === "en"
      ? `${invitedByUsername}さんからNextCRMへの招待が届きました`
      : `${invitedByUsername}さんからNextCRMへの招待が届きました`;

  return (
    <Html>
      <Head />
      <Preview>{previewText}</Preview>
      <Tailwind>
        <Body className="bg-white my-auto mx-auto font-sans">
          <Container className="border border-solid border-slate-300 rounded-md my-[40px] mx-auto p-[20px] w-[465px]">
            <Heading className="text-black text-2xl font-normal text-center p-0 my-[30px] mx-0">
              {userLanguage === "en"
                ? "チームへの招待が届きました"
                : "チームへの招待が届きました"}
            </Heading>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? `${username} 様`
                : `${username} 様`}
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              <strong>{invitedByUsername}</strong>
              {/*   (
            <Link
                href={`mailto:${invitedByEmail}`}
                className="text-blue-600 no-underline"
              >
                {invitedByEmail}
              </Link>   )*/}
              {userLanguage === "en"
                ? "さんから招待が届きました："
                : "さんから招待が届きました："}
            </Text>
            <Text>
              <strong>{process.env.NEXT_PUBLIC_APP_NAME}</strong> {"アプリ："}<strong>{process.env.NEXT_PUBLIC_APP_URL}</strong>.
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? "招待を受けるには、下のボタンからメールアドレスでログインしてください。"
                : "招待を受けるには、下のボタンからメールアドレスでログインしてください。"}
            </Text>

            <Section className="text-center mt-[32px] mb-[32px]">
              <Button
                className="bg-slate-800 rounded-md text-white  py-3 px-4 text-xs font-semibold no-underline text-center"
                href={process.env.NEXT_PUBLIC_APP_URL}
              >
                {userLanguage === "en" ? "チームに参加" : "チームに参加"}
              </Button>
            </Section>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? "または、次のURLをブラウザで開いてください："
                : "または、次のURLをブラウザで開いてください："}{" "}
              <Link
                href={process.env.NEXT_PUBLIC_APP_URL}
                className="text-blue-600 no-underline"
              >
                {process.env.NEXT_PUBLIC_APP_URL}
              </Link>
            </Text>
            <Hr className="border border-solid border-[#eaeaea] my-[26px] mx-0 w-full" />
            <Text className="text-slate-500 text-muted-foreground text-xs leading-[24px]">
              {userLanguage === "en"
                ? "この招待の宛先："
                : "この招待の宛先："}
              <span className="text-black">{username}. </span>
              {userLanguage === "en"
                ? "この招待に心当たりがない場合は、メールを破棄してください。不明な点はCRMの管理者にお問い合わせください。"
                : "この招待に心当たりがない場合は、メールを破棄してください。不明な点はCRMの管理者にお問い合わせください。"}
            </Text>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  );
};

export default InviteUserEmail;
