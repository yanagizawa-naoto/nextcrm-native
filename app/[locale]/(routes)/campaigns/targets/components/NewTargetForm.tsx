"use client";

import { z } from "zod";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { createTarget } from "@/actions/crm/targets/create-target";

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

type NewTargetFormProps = {
  onFinish: () => void;
};

export function NewTargetForm({ onFinish }: NewTargetFormProps) {
  const formSchema = z.object({
    first_name: z.string().optional(),
    last_name: z.string().optional(),
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

  type NewTargetFormValues = z.infer<typeof formSchema>;

  const form = useForm<NewTargetFormValues>({
    resolver: zodResolver(formSchema),
    mode: "onBlur",
    defaultValues: {
      status: true,
      personal_email: "",
      company_email: "",
      company_phone: "",
      city: "",
      country: "",
      industry: "",
      employees: "",
      description: "",
    },
  });

  const onSubmit = async (data: NewTargetFormValues) => {
    if (!data.last_name && !data.company) {
      form.setError("root.serverError", {
        message: "姓または会社名を入力してください。",
      });
      return;
    }
    const result = await createTarget(data);
    if (result?.error) {
      form.setError("root.serverError", { message: result.error });
    } else {
      toast.success("営業対象を作成しました");
      form.reset({ status: true });
      onFinish();
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
                <FormLabel>{"姓"}</FormLabel>
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
        <Button disabled={form.formState.isSubmitting} type="submit" className="w-full">
          {form.formState.isSubmitting ? (
            <span className="flex items-center animate-pulse">{"保存しています…"}</span>
          ) : (
            "対象顧客を作成"
          )}
        </Button>
      </form>
    </Form>
  );
}
