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
  commentFromUser: string;
  username: string;
  userLanguage: string;
  comment: string;
  taskId: string;
}

const baseUrl = process.env.NEXT_PUBLIC_APP_URL;

export const NewTaskCommentEmail = ({
  commentFromUser,
  username,
  userLanguage,
  comment,
  taskId,
}: VercelInviteUserEmailProps) => {
  const previewText =
    userLanguage === "en"
      ? `${process.env.NEXT_PUBLIC_APP_NAME}：タスクに新しいコメント`
      : `${process.env.NEXT_PUBLIC_APP_NAME}：タスクに新しいコメント`;

  return (
    <Html>
      <Head />
      <Preview>{previewText}</Preview>
      <Tailwind>
        <Body className="bg-white my-auto mx-auto font-sans">
          <Container className="border border-solid border-[#eaeaea] rounded my-[40px] mx-auto p-[20px] w-[465px]">
            <Heading className="text-black text-2xl font-normal text-center p-0 my-[30px] mx-0">
              {userLanguage === "en"
                ? "通知を受け取るタスクに新しいコメントがあります"
                : "通知を受け取るタスクに新しいコメントがあります"}
            </Heading>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? `${username} 様`
                : `${username} 様`}
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              <strong>{commentFromUser}</strong>
              {userLanguage === "en"
                ? "さんが、通知を受け取るプロジェクトにコメントしました。"
                : "さんが、通知を受け取るプロジェクトにコメントしました。"}
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en" ? "コメント：" : "コメント："}
              <strong>{comment}</strong>
            </Text>
            <Text className="text-black text-sm leading-[24px]">
              {userLanguage === "en"
                ? "詳細はこちら："
                : "詳細はこちら："}

              <strong>{`${process.env.NEXT_PUBLIC_APP_URL}/projects/tasks/viewtask/${taskId}`}</strong>
            </Text>
            <Section className="text-center mt-[32px] mb-[32px]">
              <Button
                className="bg-slate-800 rounded-md text-white  py-3 px-4 text-xs font-semibold no-underline text-center"
                href={`${process.env.NEXT_PUBLIC_APP_URL}/projects/tasks/viewtask/${taskId}`}
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

export default NewTaskCommentEmail;
