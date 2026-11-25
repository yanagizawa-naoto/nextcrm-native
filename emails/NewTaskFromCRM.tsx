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
  taskFromUser: string;
  username: string;
  userLanguage: string;
  taskData: any;
}

const baseUrl = process.env.NEXT_PUBLIC_APP_URL;

export const NewTaskFromCRMEmail = ({
  taskFromUser,
  username,
  userLanguage,
  taskData,
}: VercelInviteUserEmailProps) => {
  const previewText =
    userLanguage === "en"
      ? `${process.env.NEXT_PUBLIC_APP_NAME}：タスクのお知らせ`
      : `${process.env.NEXT_PUBLIC_APP_NAME}：タスクのお知らせ`;

  return (
    <Html>
      <Head />
      <Preview>{previewText}</Preview>
      <Tailwind>
        <Body className="bg-white my-auto mx-auto font-sans">
          <Container className="border border-solid border-[#eaeaea] rounded my-[40px] mx-auto p-[20px] w-[465px]">
            <Heading className="text-black text-2xl font-normal text-center p-0 my-[30px] mx-0">
              {userLanguage === "en"
                ? "営業管理に新しいタスクがあります"
                : "営業管理に新しいタスクがあります"}
            </Heading>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? `${username} 様`
                : `${username} 様`}
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              <strong>{taskFromUser}</strong>
              {userLanguage === "en"
                ? "さんがタスクを作成し、あなたに割り当てました。"
                : "さんがタスクを作成し、あなたに割り当てました。"}
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? "詳細はこちら："
                : "詳細はこちら："}

              <strong>{`${process.env.NEXT_PUBLIC_APP_URL}/projects/tasks/viewtask/${taskData.id}`}</strong>
            </Text>
            <Section className="text-center mt-[32px] mb-[32px]">
              <Button
                className="bg-slate-800 rounded-md text-white  py-3 px-4 text-xs font-semibold no-underline text-center"
                href={`${process.env.NEXT_PUBLIC_APP_URL}/projects/tasks/viewtask/${taskData.id}`}
              >
                {userLanguage === "en" ? "タスクの詳細を見る" : "タスクの詳細を見る"}
              </Button>
            </Section>
            <Hr className="border border-solid border-[#eaeaea] my-[26px] mx-0 w-full" />
            <Text className="text-[#666666] text-xs leading-[24px]">
              {userLanguage === "en"
                ? "このメッセージの宛先："
                : "このメッセージの宛先："}
              <span className="text-black">{username}</span>.
              <span className="text-black"></span>.
              {userLanguage === "en"
                ? "このメールに心当たりがない場合は、破棄してください。不明な点はCRMの管理者にお問い合わせください。"
                : "このメールに心当たりがない場合は、破棄してください。不明な点はCRMの管理者にお問い合わせください。"}
            </Text>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  );
};

export default NewTaskFromCRMEmail;
