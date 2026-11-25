import { Button } from "@/components/ui/button";
import { getSessionAnyStatus } from "@/lib/auth-server";
import { prismadb } from "@/lib/prisma";
import Link from "next/link";
import { redirect } from "next/navigation";
import TryAgain from "./components/TryAgain";
import { Users } from "@prisma/client";

const PendingPage = async () => {
  const adminUsers: Users[] = await prismadb.users.findMany({
    where: {
      role: "admin",
      userStatus: "ACTIVE",
    },
  });

  const session = await getSessionAnyStatus();

  if (session?.user.userStatus !== "PENDING") {
    return redirect("/");
  }

  return (
    <div className="flex flex-col space-y-5 justify-center items-center max-w-3xl border rounded-md p-10 shadow-md">
      {/*       <pre>
        <code>{JSON.stringify(session, null, 2)}</code>
      </pre> */}
      <div className="flex flex-col">
        <h1 className="text-3xl">
          {process.env.NEXT_PUBLIC_APP_NAME} {"— 利用には管理者の承認が必要です"}</h1>
        <p>
          {"ようこそ"}{process.env.NEXT_PUBLIC_APP_NAME}{"。管理者にアカウントの承認を依頼してください。最初のユーザーの場合は、システムの管理担当者にお問い合わせください。"}</p>
      </div>
      <div className="flex flex-col justify-center ">
        <h2 className="flex justify-center text-xl">{"管理者一覧"}</h2>
        {adminUsers &&
          adminUsers?.map((user: Users) => (
            <div
              key={user.id}
              className="flex flex-col p-5 m-2 gap-3 border rounded-md"
            >
              <div>
                <p className="font-bold">{user.name}</p>
                <p>{user.id}</p>
                <p>
                  <Link href={`mailto:  ${user.email}`}>{user.email}</Link>
                </p>
              </div>
            </div>
          ))}
      </div>
      <div className="flex flex-col md:flex-row space-x-2 justify-center items-center">
        <Button asChild>
          <Link href="/sign-in">{"別のアカウントでログイン"}</Link>
        </Button>
        <p>{"または"}</p>
        <TryAgain />
      </div>
    </div>
  );
};

export default PendingPage;
