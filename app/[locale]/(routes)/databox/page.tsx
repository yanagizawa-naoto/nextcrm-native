import Heading from "@/components/ui/heading";
import { Separator } from "@/components/ui/separator";
import React from "react";
import Container from "../components/ui/Container";

type Props = {};

const CrmPage = (props: Props) => {
  return (
    <Container
      title="データボックス"
      description={
        "データボックスの情報を確認します"
      }
    >
      <div>{"この機能の内容を表示します"}</div>
    </Container>
  );
};

export default CrmPage;
