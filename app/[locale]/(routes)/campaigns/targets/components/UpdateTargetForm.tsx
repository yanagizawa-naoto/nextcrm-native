"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { z } from "zod";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { updateTarget } from "@/actions/crm/targets/update-target";
import { convertTarget } from "@/actions/crm/targets/convert-target";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Switch } from "@/components/ui/switch";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";

type UpdateTargetFormProps = {
  initialData: any;
  setOpen: (value: boolean) => void;
};

export function UpdateTargetForm({ initialData, setOpen }: UpdateTargetFormProps) {
  const router = useRouter();
  const [converting, setConverting] = useState(false);

  const handleConvert = async () => {
    setConverting(true);
    const result = await convertTarget(initialData.id);
    setConverting(false);
    if ("error" in result) {
      toast.error(result.error);
    } else {
      toast.success("取引先と連絡先を作成しました。");
      router.refresh();
    }
  };

  const formSchema = z.object({
    first_name: z.string().optional(),
    last_name: z.string().min(1, "姓を入力してください"),
    email: z.string().optional(),
    mobile_phone: z.string().optional(),
    office_phone: z.string().optional(),
    company: z.string().optional(),
    company_website: z.string().optional(),
    personal_website: z.string().optional(),
    position: z.string().optional(),
    social_x: z.string().optional(),
    social_linkedin: z.string().optional(),
    social_instagram: z.string().optional(),
    social_facebook: z.string().optional(),
    personal_email: z.string().optional(),
    company_email:  z.string().optional(),
    company_phone:  z.string().optional(),
    city:           z.string().optional(),
    country:        z.string().optional(),
    industry:       z.string().optional(),
    employees:      z.string().optional(),
    description:    z.string().optional(),
    status: z.boolean(),
  });

  type UpdateTargetFormValues = z.infer<typeof formSchema>;

  const form = useForm<UpdateTargetFormValues>({
    resolver: zodResolver(formSchema),
    mode: "onBlur",
    defaultValues: {
      first_name: initialData.first_name || "",
      last_name: initialData.last_name || "",
      email: initialData.email || "",
      mobile_phone: initialData.mobile_phone || "",
      office_phone: initialData.office_phone || "",
      company: initialData.company || "",
      company_website: initialData.company_website || "",
      personal_website: initialData.personal_website || "",
      position: initialData.position || "",
      social_x: initialData.social_x || "",
      social_linkedin: initialData.social_linkedin || "",
      social_instagram: initialData.social_instagram || "",
      social_facebook: initialData.social_facebook || "",
      personal_email: initialData?.personal_email || "",
      company_email: initialData?.company_email || "",
      company_phone: initialData?.company_phone || "",
      city: initialData?.city || "",
      country: initialData?.country || "",
      industry: initialData?.industry || "",
      employees: initialData?.employees || "",
      description: initialData?.description || "",
      status: initialData.status ?? true,
    },
  });

  const onSubmit = async (data: UpdateTargetFormValues) => {
    const result = await updateTarget({ id: initialData.id, ...data });
    if (result?.error) {
      form.setError("root.serverError", { message: result.error });
    } else {
      toast.success("営業対象を更新しました");
      setOpen(false);
    }
  };

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4 px-2">
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="last_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"姓（必須）"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="山田" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="first_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"名"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="太郎" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="email"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"メールアドレス"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="john@example.com" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="mobile_phone"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"携帯電話番号"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="+1 234 567 890" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="office_phone"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"会社電話番号"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="+1 234 567 891" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="position"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"部署・役職"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="代表取締役" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="company"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"会社名"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="株式会社サンプル" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="company_website"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{"会社のウェブサイト"}</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="https://acme.com" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <FormField
          control={form.control}
          name="personal_website"
          render={({ field }) => (
            <FormItem>
              <FormLabel>{"個人のウェブサイト"}</FormLabel>
              <FormControl>
                <Input disabled={form.formState.isSubmitting} placeholder="https://johndoe.com" {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="social_linkedin"
            render={({ field }) => (
              <FormItem>
                <FormLabel>LinkedIn</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="https://linkedin.com/in/john" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="social_x"
            render={({ field }) => (
              <FormItem>
                <FormLabel>X (Twitter)</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="https://x.com/john" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField
            control={form.control}
            name="social_instagram"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Instagram</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="https://instagram.com/john" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="social_facebook"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Facebook</FormLabel>
                <FormControl>
                  <Input disabled={form.formState.isSubmitting} placeholder="https://facebook.com/john" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField control={form.control} name="personal_email" render={({ field }) => (
            <FormItem><FormLabel>{"個人メールアドレス"}</FormLabel>
              <FormControl><Input placeholder="john@personal.com" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
          <FormField control={form.control} name="company_email" render={({ field }) => (
            <FormItem><FormLabel>{"会社メールアドレス"}</FormLabel>
              <FormControl><Input placeholder="info@company.com" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
        </div>
        <FormField control={form.control} name="company_phone" render={({ field }) => (
          <FormItem><FormLabel>{"会社電話番号"}</FormLabel>
            <FormControl><Input placeholder="+1 800 000 0000" {...field} value={field.value ?? ''} /></FormControl>
            <FormMessage />
          </FormItem>
        )} />
        <div className="grid grid-cols-2 gap-4">
          <FormField control={form.control} name="city" render={({ field }) => (
            <FormItem><FormLabel>{"市区町村"}</FormLabel>
              <FormControl><Input placeholder="東京都" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
          <FormField control={form.control} name="country" render={({ field }) => (
            <FormItem><FormLabel>{"国"}</FormLabel>
              <FormControl><Input placeholder="日本" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <FormField control={form.control} name="industry" render={({ field }) => (
            <FormItem><FormLabel>{"業種"}</FormLabel>
              <FormControl><Input placeholder="SaaS" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
          <FormField control={form.control} name="employees" render={({ field }) => (
            <FormItem><FormLabel>{"従業員"}</FormLabel>
              <FormControl><Input placeholder="50-200" {...field} value={field.value ?? ''} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
        </div>
        <FormField control={form.control} name="description" render={({ field }) => (
          <FormItem><FormLabel>{"品名・内容"}</FormLabel>
            <FormControl><Input placeholder="会社の概要" {...field} value={field.value ?? ''} /></FormControl>
            <FormMessage />
          </FormItem>
        )} />
        <FormField
          control={form.control}
          name="status"
          render={({ field }) => (
            <FormItem className="flex flex-row items-center justify-between rounded-lg border p-4">
              <div className="space-y-0.5">
                <FormLabel className="text-base">{"有効な営業対象"}</FormLabel>
              </div>
              <FormControl>
                <Switch
                  checked={field.value}
                  onCheckedChange={field.onChange}
                />
              </FormControl>
            </FormItem>
          )}
        />
        {form.formState.errors.root?.serverError && (
          <p className="text-sm text-destructive" aria-live="polite">
            {form.formState.errors.root.serverError.message}
          </p>
        )}
        {initialData?.converted_at ? (
          <div className="rounded-md border p-3 bg-muted text-sm text-muted-foreground">
            {"取引先・連絡先への変換日："}{new Date(initialData.converted_at).toLocaleDateString("ja-JP")}
          </div>
        ) : (
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button type="button" variant="outline" disabled={converting}>
                {"取引先に変換"}</Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>{"取引先と連絡先を作成しますか？"}</AlertDialogTitle>
                <AlertDialogDescription>
                  {"新しい取引先「"}{initialData?.company || initialData?.last_name}{"」と連絡先「"}{initialData?.last_name} {initialData?.first_name}{"」を作成し、営業対象を変換済みにします。"}</AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>{"取消"}</AlertDialogCancel>
                <AlertDialogAction onClick={handleConvert} disabled={converting}>
                  {converting ? "変換中…" : "変換"}
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        )}
        <Button disabled={form.formState.isSubmitting} type="submit" className="w-full">
          {form.formState.isSubmitting ? (
            <span className="flex items-center animate-pulse">{"保存しています…"}</span>
          ) : (
            "対象顧客を更新"
          )}
        </Button>
      </form>
    </Form>
  );
}
