import { getSession } from "@/lib/auth-server";
import { redirect } from "next/navigation";
import React from "react";
import Container from "../../../components/ui/Container";
import { getAccountsTasks } from "@/actions/crm/account/get-tasks";
import { getUserCRMTasks } from "@/actions/crm/tasks/get-user-tasks";

const UserCRMDashboard = async () => {
  const session = await getSession();

  if (!session) {
    redirect("/auth/signin");
  }

  const task = await getUserCRMTasks(session.user.id);

  return (
    <div>
      <Container
        title={`${session.user.name} | CRM Dashboard (in-progress) `}
        description="営業情報をまとめて確認できます"
      >
        <div className="grid grid-cols-2 w-full ">
          <div className="">{"電話対応の概要"}</div>
          <div className="">
            <h1>{"取引先のタスク"}</h1>
            <pre>{JSON.stringify(task, null, 2)}</pre>
          </div>
          <div className="">{"面談の概要"}</div>
          <div className="">
            <h1></h1>
          </div>
          <div className="">{"見込み客の概要"}</div>
          <div className="">
            <h1></h1>
          </div>
        </div>
      </Container>
    </div>
  );
};

export default UserCRMDashboard;
