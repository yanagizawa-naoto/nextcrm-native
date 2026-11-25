"use client";

import { Button } from "@/components/ui/button";
import { DialogTrigger } from "@/components/ui/dialog";
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { Icons } from "@/components/ui/icons";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";

import React, { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { updateProject } from "@/actions/projects/update-project";

type Props = {
  initialData: any;
  openEdit: (value: boolean) => void;
};

const UpdateProjectForm = ({ initialData, openEdit }: Props) => {
  const [open, setOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  const [isMounted, setIsMounted] = useState(false);

  const router = useRouter();

  const formSchema = z.object({
    id: z.string(),
    title: z.string().min(3).max(255),
    description: z.string().min(3).max(500),
    visibility: z.string().min(3).max(255),
  });

  type NewAccountFormValues = z.infer<typeof formSchema>;

  const form = useForm<NewAccountFormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: initialData,
  });

  useEffect(() => {
    setIsMounted(true);
  }, []);

  if (!isMounted) {
    return null;
  }

  //Actions

  const onSubmit = async (data: NewAccountFormValues) => {
    setIsLoading(true);
    try {
      const result = await updateProject(data);
      if (result?.error) {
        toast.error(result.error);
      } else {
        toast.success(`Project: ${data.title}, update successfully`);
      }
    } catch (error: any) {
      toast.error(error?.message);
    } finally {
      setIsLoading(false);
      setOpen(false);
      openEdit(false);
      router.refresh();
    }
  };

  return (
    <div className="flex w-full py-5 ">
      <Form {...form}>
        <form
          onSubmit={form.handleSubmit(onSubmit)}
          className="h-full w-full space-y-3"
        >
          <div className="flex flex-col space-y-3">
            <FormField
              control={form.control}
              name="title"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{"プロジェクト名"}</FormLabel>
                  <FormControl>
                    <Input
                      disabled={isLoading}
                      placeholder="プロジェクト名を入力"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="description"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{"プロジェクトの説明"}</FormLabel>
                  <FormControl>
                    <Textarea
                      rows={10}
                      disabled={isLoading}
                      placeholder="プロジェクトの説明を入力"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
            <FormField
              control={form.control}
              name="visibility"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>{"プロジェクトの公開範囲"}</FormLabel>
                  <Select
                    onValueChange={field.onChange}
                    defaultValue={field.value}
                  >
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="公開範囲を選択" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      <SelectItem value={"public"}>{"公開"}</SelectItem>
                      <SelectItem value={"private"}>{"非公開"}</SelectItem>
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />
          </div>
          <div className="flex w-full justify-end space-x-2 pt-2">
            <DialogTrigger asChild>
              <Button variant={"destructive"}>{"取消"}</Button>
            </DialogTrigger>
            <Button type="submit" disabled={isLoading}>
              {isLoading ? (
                <Icons.spinner className="animate-spin" />
              ) : (
                "更新"
              )}
            </Button>
          </div>
        </form>
      </Form>
    </div>
  );
};

export default UpdateProjectForm;
