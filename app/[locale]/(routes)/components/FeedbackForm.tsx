"use client";

import * as z from "zod";
import { useState } from "react";
import { sendFeedback } from "@/actions/feedback/send-feedback";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

import {
  Form,
  FormField,
  FormItem,
  FormLabel,
  FormControl,
  FormDescription,
  FormMessage,
} from "@/components/ui/form";
import { Button } from "@/components/ui/button";

import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { Icons } from "@/components/ui/icons";

const formSchema = z.object({
  feedback: z.string().min(1, {
    message: "内容を入力してください。",
  }),
});

interface FeedbackFormProps {
  setOpen: (open: boolean) => void;
}

const FeedbackForm = ({ setOpen }: FeedbackFormProps) => {
  const [loading, setLoading] = useState(false);

  const form = useForm({
    resolver: zodResolver(formSchema),
  });

  const onSubmit = async (data: any) => {
    setLoading(true);
    try {
      const result = await sendFeedback({ feedback: data.feedback });
      if (result?.error) {
        toast.error(result.error);
      } else {
        toast.success("ご意見をお送りいただき、ありがとうございます。");
        setOpen(false);
      }
    } catch (error) {
      console.error(error);
      toast.error("処理に失敗しました。しばらくしてからお試しください。");
    } finally {
      setLoading(false);
    }
  };

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-3">
        <FormField
          control={form.control}
          name="feedback"
          render={({ field }) => (
            <FormItem>
              <FormLabel>{"ご意見を送る"}</FormLabel>
              <FormControl>
                <Textarea
                  placeholder="ご意見・ご要望"
                  disabled={loading}
                  {...field}
                />
              </FormControl>
              <FormDescription className="text-xs text-muted-foreground">
                {"改善のため、ご意見・ご要望をお寄せください。"}</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />
        <div className="flex justify-end space-x-2">
          <Button
            variant={"outline"}
            onClick={() => setOpen(false)}
            disabled={loading}
          >
            {"取消"}</Button>
          <Button type="submit" variant={"secondary"} disabled={loading}>
            {loading ? (
              <div className="flex space-x-2">
                <Icons.spinner className="h-4 w-4 animate-spin" />
                <span>{"送信しています…"}</span>
              </div>
            ) : (
              "申請"
            )}
          </Button>
        </div>
      </form>
    </Form>
  );
};

export default FeedbackForm;
