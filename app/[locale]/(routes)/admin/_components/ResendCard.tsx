import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

import { getResendKeyStatus } from "@/lib/resend";

import { Input } from "@/components/ui/input";
import { setResendKey } from "@/actions/admin/system/set-resend-key";

const ResendCard = async () => {
  const resend_key = await getResendKeyStatus();

  return (
    <Card className="min-w-[350px] max-w-[450px]">
      <CardHeader className="text-lg">
        <CardTitle>{"ResendのAPIキー"}</CardTitle>
        <CardDescription className="text-xs">
          <p>{"環境変数のAPIキー："}</p>
          <p>{resend_key.envKey ?? "未設定"}</p>
          <p>{"保存済みAPIキー："}</p>
          <p>{resend_key.dbKey ?? "未設定"}</p>
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        <form action={setResendKey}>
          <div>
            <input type="hidden" name="id" value={resend_key.id} />
            <Input type="text" name="serviceKey" placeholder="APIキーを入力" />
          </div>
          <div className="flex justify-end pt-2 gap-2">
            <Button type={"reset"}>{"リセット"}</Button>
            <Button type="submit">{"Resendのキーを保存"}</Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
};

export default ResendCard;
