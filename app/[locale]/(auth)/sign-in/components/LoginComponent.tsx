"use client";

import React, { useState } from "react";
import { authClient } from "@/lib/auth-client";

import { Icons } from "@/components/ui/icons";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { MailIcon } from "lucide-react";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
} from "@/components/ui/input-otp";

type Step = "email" | "otp";

export function LoginComponent() {
  const [isLoading, setIsLoading] = useState(false);
  const [step, setStep] = useState<Step>("email");
  const [email, setEmail] = useState("");
  const [otp, setOtp] = useState("");

  const loginWithGoogle = async () => {
    setIsLoading(true);
    try {
      await authClient.signIn.social({
        provider: "google",
        callbackURL: "/",
      });
    } catch (error) {
      toast.error("Googleでログインできませんでした。");
    } finally {
      setIsLoading(false);
    }
  };

  const sendOtp = async () => {
    if (!email) {
      toast.error("メールアドレスを入力してください。");
      return;
    }
    setIsLoading(true);
    try {
      const { error } = await authClient.emailOtp.sendVerificationOtp({
        email,
        type: "sign-in",
      });
      if (error) {
        toast.error(error.message || "認証コードを送信できませんでした。");
        return;
      }
      setStep("otp");
      toast.success("認証コードをメールで送信しました。");
    } catch (error) {
      toast.error("認証コードを送信できませんでした。");
    } finally {
      setIsLoading(false);
    }
  };

  const verifyOtp = async () => {
    if (otp.length !== 6) {
      toast.error("6桁の認証コードを入力してください。");
      return;
    }
    setIsLoading(true);
    try {
      const { error } = await authClient.signIn.emailOtp({
        email,
        otp,
      });
      if (error) {
        toast.error(error.message || "確認コードが無効か、有効期限が切れています。");
        return;
      }
      toast.success("ログインしました。");
      window.location.href = new URL("/", window.location.origin).href;
    } catch (error) {
      toast.error("認証できませんでした。");
    } finally {
      setIsLoading(false);
    }
  };

  if (process.env.NEXT_PUBLIC_DESKTOP_MODE === "1") {
    return (
      <Card className="shadow-lg my-5">
        <CardHeader>
          <CardTitle>NextCRMへようこそ</CardTitle>
          <CardDescription>このMacに保存されたCRMを開きます。</CardDescription>
        </CardHeader>
        <CardContent>
          <Button className="w-full" onClick={() => {
            const bridge = (window as Window & { webkit?: { messageHandlers?: { desktopSignIn?: { postMessage: (value: string) => void } } } }).webkit?.messageHandlers?.desktopSignIn;
            if (bridge) bridge.postMessage("sign-in");
            else toast.info("MacのNextCRMアプリを開いてログインしてください。");
          }}>このMacでログイン</Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="shadow-lg my-5">
      <CardHeader className="space-y-1">
        <CardTitle className="text-2xl">{"ログイン"}</CardTitle>
        <CardDescription>{"ログイン方法を選択してください"}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <Button
          variant="outline"
          onClick={loginWithGoogle}
          disabled={isLoading}
          className="w-full"
        >
          <Icons.google className="mr-2 h-4 w-4" />
          {"Googleでログイン"}</Button>

        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <span className="w-full border-t" />
          </div>
          <div className="relative flex justify-center text-xs uppercase">
            <span className="bg-background px-2 text-muted-foreground">
              {"またはメールでログイン"}</span>
          </div>
        </div>

        {step === "email" && (
          <div className="grid gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="email">{"メールアドレス"}</Label>
              <Input
                id="email"
                type="email"
                placeholder="name@domain.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={isLoading}
                onKeyDown={(e) => e.key === "Enter" && sendOtp()}
              />
            </div>
            <Button onClick={sendOtp} disabled={isLoading || !email}>
              <MailIcon className="mr-2 h-4 w-4" />
              {"認証コードを送信"}</Button>
          </div>
        )}

        {step === "otp" && (
          <div className="grid gap-3">
            <p className="text-sm text-muted-foreground">
              {"6桁の認証コードを入力してください。送信先："}<strong>{email}</strong>
            </p>
            <div className="flex justify-center">
              <InputOTP
                maxLength={6}
                value={otp}
                onChange={setOtp}
                disabled={isLoading}
              >
                <InputOTPGroup>
                  <InputOTPSlot index={0} />
                  <InputOTPSlot index={1} />
                  <InputOTPSlot index={2} />
                  <InputOTPSlot index={3} />
                  <InputOTPSlot index={4} />
                  <InputOTPSlot index={5} />
                </InputOTPGroup>
              </InputOTP>
            </div>
            <Button onClick={verifyOtp} disabled={isLoading || otp.length !== 6}>
              {"認証してログイン"}</Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setStep("email");
                setOtp("");
              }}
              disabled={isLoading}
            >
              {"別のメールアドレスを使用"}</Button>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
